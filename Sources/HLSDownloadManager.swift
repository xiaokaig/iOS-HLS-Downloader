import Foundation
import Combine
import CommonCrypto
import AVFoundation
import CryptoKit

enum HLSDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case unsupportedPlaylist
    case livePlaylist
    case unsupportedEncryption
    case invalidKey
    case invalidRange
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无效响应"
        case .httpStatus(let code): return "HTTP 请求失败：\(code)"
        case .unsupportedPlaylist: return "暂不支持该播放列表格式或加密方式"
        case .livePlaylist: return "当前版本仅支持已结束的点播列表（VOD）"
        case .unsupportedEncryption: return "仅支持 identity 格式的 AES-128-CBC；不支持 DRM 或 SAMPLE-AES"
        case .invalidKey: return "AES-128 密钥无效（应为 16 字节）"
        case .invalidRange: return "服务器未能提供请求的字节范围"
        case .emptyDownload: return "下载结果为空"
        }
    }
}

@MainActor
final class HLSDownloadManager: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "等待下载"
    @Published private(set) var outputURL: URL?
    @Published private(set) var isDownloading = false
    @Published private(set) var conversionWarning: String?

    private var keyCache: [URL: Data] = [:]
    private var lastTaskDirectory: URL?

    func inspectPlaylist(_ url: URL, cookies: [HTTPCookie] = []) async throws -> HLSInspection {
        status = "解析播放列表…"
        let fetched = try await fetchText(url, cookies: cookies)
        let parsed = try HLSParser.parse(fetched.text, baseURL: fetched.finalURL)
        return HLSInspection(
            variants: parsed.variants,
            segmentCount: parsed.segments.count,
            duration: parsed.segments.reduce(0) { $0 + $1.duration },
            isEndList: parsed.variants.isEmpty ? parsed.isEndList : true
        )
    }

    func variants(for url: URL, cookies: [HTTPCookie] = []) async throws -> [HLSVariant] {
        try await inspectPlaylist(url, cookies: cookies).variants
    }

    func start(url: URL, cookies: [HTTPCookie] = [], fileName: String? = nil, stripMarkedAds: Bool = true) async throws -> URL {
        guard !isDownloading else { throw HLSDownloadError.unsupportedPlaylist }
        isDownloading = true
        progress = 0
        outputURL = nil
        conversionWarning = nil
        keyCache.removeAll()
        status = "读取播放列表…"
        defer { isDownloading = false }

        var playlistURL = url
        var playlist: HLSPlaylist?
        for _ in 0..<4 {
            let fetched = try await fetchText(playlistURL, cookies: cookies)
            let parsed = try HLSParser.parse(fetched.text, baseURL: fetched.finalURL)
            if parsed.variants.isEmpty {
                playlist = parsed
                break
            }
            guard let best = parsed.variants.first else { throw HLSDownloadError.unsupportedPlaylist }
            playlistURL = best.url
            status = "选择清晰度：\(best.resolution ?? "自动")"
        }

        guard let mediaPlaylist = playlist else { throw HLSDownloadError.unsupportedPlaylist }
        guard mediaPlaylist.isEndList else { throw HLSDownloadError.livePlaylist }
        guard !mediaPlaylist.segments.isEmpty else { throw HLSParserError.emptyPlaylist }
        let markedAdCount = mediaPlaylist.segments.filter(\.isAd).count
        let downloadSegments = mediaPlaylist.segments.filter { !stripMarkedAds || !$0.isAd }
        guard !downloadSegments.isEmpty else { throw HLSDownloadError.emptyDownload }
        if stripMarkedAds && markedAdCount > 0 {
            status = "已识别 \(markedAdCount) 个广告分片，正在跳过…"
        }

        let hasMap = downloadSegments.contains { $0.map != nil }
        let ext = hasMap ? "mp4" : "ts"
        let safeBase = Self.safeFileName(fileName ?? url.deletingPathExtension().lastPathComponent)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var filename = "\(safeBase).\(ext)"
        var destination = documents.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            filename = "\(safeBase) (\(suffix)).\(ext)"
            destination = documents.appendingPathComponent(filename)
            suffix += 1
        }
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw HLSDownloadError.invalidResponse
        }
        let output = try FileHandle(forWritingTo: destination)
        var preserveDestination = false
        defer {
            try? output.close()
            if !preserveDestination { try? FileManager.default.removeItem(at: destination) }
        }

        let total = downloadSegments.count
        let taskDirectory = persistentTaskDirectory(for: playlistURL)
        lastTaskDirectory = taskDirectory
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        var signatureLines: [String] = []
        signatureLines.reserveCapacity(downloadSegments.count)
        for segment in downloadSegments {
            let range: String
            if let byteRange = segment.byteRange {
                range = String(byteRange.offset) + ":" + String(byteRange.length)
            } else {
                range = "-"
            }

            let key: String
            if let encryption = segment.key {
                let keyURL = encryption.url?.absoluteString ?? "-"
                let iv = encryption.iv?.base64EncodedString() ?? "sequence-iv"
                key = encryption.method + ":" + keyURL + ":" + iv + ":" + encryption.keyFormat
            } else {
                key = "clear"
            }

            let map: String
            if let initialization = segment.map {
                let offset = initialization.byteRange?.offset ?? 0
                let length = initialization.byteRange?.length ?? 0
                map = initialization.url.absoluteString + ":" + String(offset) + ":" + String(length)
            } else {
                map = "-"
            }

            let line = String(segment.sequence) + "|" + segment.url.absoluteString + "|" + range + "|" + key + "|" + map
            signatureLines.append(line)
        }
        let signature = signatureLines.joined(separator: "\n")
        let signatureURL = taskDirectory.appendingPathComponent("playlist.signature")
        if let saved = try? String(contentsOf: signatureURL, encoding: String.Encoding.utf8), saved != signature {
            try? FileManager.default.removeItem(at: taskDirectory)
            try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        }
        try signature.write(to: signatureURL, atomically: true, encoding: String.Encoding.utf8)

        status = "并发下载分片…"
        var completed = 0
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            var nextIndex = 0
            let concurrency = 6
            while nextIndex < min(concurrency, total) {
                let index = nextIndex
                let segment = downloadSegments[index]
                group.addTask {
                    try await self.downloadSegmentToCache(
                        segment, index: index, directory: taskDirectory, cookies: cookies
                    )
                }
                nextIndex += 1
            }
            while let _ = try await group.next() {
                completed += 1
                self.progress = Double(completed) / Double(total) * 0.75
                if nextIndex < total {
                    let index = nextIndex
                    let segment = downloadSegments[index]
                    group.addTask {
                        try await self.downloadSegmentToCache(
                            segment, index: index, directory: taskDirectory, cookies: cookies
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        status = "后台按顺序组装视频…"
        var lastMap: HLSMap?
        var discontinuityOffsets: [UInt64] = []
        for (index, segment) in downloadSegments.enumerated() {
            try Task.checkCancellation()
            if let map = segment.map, map != lastMap {
                let mapTemp = try await fetchTemporaryFile(map.url, range: map.byteRange, cookies: cookies)
                defer { try? FileManager.default.removeItem(at: mapTemp.fileURL) }
                var mapKeyData: Data?
                if let key = segment.key {
                    guard key.method == "AES-128", key.keyFormat == "identity", key.iv != nil else {
                        throw HLSDownloadError.unsupportedEncryption
                    }
                    mapKeyData = try await fetchKey(key, cookies: cookies)
                }
                let mapIV = segment.key?.iv
                try await Task.detached(priority: .utility) {
                    if let mapKeyData, let mapIV {
                        let bytes = try Self.readDownloadedBytes(mapTemp, range: map.byteRange)
                        let clear = try Self.decryptAES128(bytes, key: mapKeyData, iv: mapIV)
                        try output.write(contentsOf: clear)
                    } else {
                        try Self.appendDownloadedFile(mapTemp, range: map.byteRange, to: output)
                    }
                }.value
                lastMap = map
            }
            let cached = cachedSegmentURL(index: index, directory: taskDirectory)
            let statusCode = (try? String(contentsOf: cachedStatusURL(index: index, directory: taskDirectory), encoding: .utf8))
                .flatMap(Int.init) ?? 200
            let item = (fileURL: cached, statusCode: statusCode)
            var segmentKeyData: Data?
            var segmentIV: Data?
            if let key = segment.key {
                guard key.method == "AES-128", key.keyFormat == "identity", key.url != nil else {
                    throw HLSDownloadError.unsupportedEncryption
                }
                segmentKeyData = try await fetchKey(key, cookies: cookies)
                segmentIV = key.iv ?? Self.sequenceIV(segment.sequence)
            }
            if !hasMap, index > 0, segment.startsDiscontinuity {
                discontinuityOffsets.append(output.offsetInFile)
            }
            try await Task.detached(priority: .utility) {
                if let segmentKeyData, let segmentIV {
                    let encrypted = try Self.readDownloadedBytes(item, range: segment.byteRange)
                    let clear = try Self.decryptAES128(encrypted, key: segmentKeyData, iv: segmentIV)
                    try output.write(contentsOf: clear)
                } else {
                    try Self.appendDownloadedFile(item, range: segment.byteRange, to: output)
                }
            }.value
            progress = 0.75 + Double(index + 1) / Double(total) * 0.25
        }

        try output.synchronize()
        try output.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard ((attributes[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw HLSDownloadError.emptyDownload
        }

        var finalURL = destination
        if !hasMap {
            let hasDiscontinuity = mediaPlaylist.segments.contains(where: \.startsDiscontinuity)
            status = hasDiscontinuity
                ? "检测到 HLS 时间线断点，正在尝试 MP4 转封装并加强校验…"
                : "正在尝试 MP4 转封装…"
            do {
                finalURL = try await remuxTransportStream(destination, discontinuityOffsets: discontinuityOffsets)
            } catch {
                conversionWarning = "MP4 完整性验证/转换失败，已保留原始 TS 文件：\(error.localizedDescription)"
            }
        }
        outputURL = finalURL
        preserveDestination = true
        try? FileManager.default.removeItem(at: taskDirectory)
        let adSummary = stripMarkedAds && markedAdCount > 0 ? "（已跳过 \(markedAdCount) 个广告分片）" : ""
        if finalURL.pathExtension.lowercased() == "mp4" {
            status = "下载完成（MP4）\(adSummary)"
        } else if conversionWarning?.contains("时间线断点") == true {
            status = "下载完成（TS，保留原始时间线）\(adSummary)"
        } else if conversionWarning != nil {
            status = "下载完成（TS，MP4 转换失败）\(adSummary)"
        } else {
            status = "下载完成（TS）\(adSummary)"
        }
        return finalURL
    }

    func discardResumeCache() {
        if let directory = lastTaskDirectory {
            try? FileManager.default.removeItem(at: directory)
            lastTaskDirectory = nil
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\\\:?%*|\"<>")
            .union(.controlCharacters)
        let cleaned = value.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "_")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let shortened = String(cleaned.prefix(100))
        return shortened.isEmpty ? "Video" : shortened
    }

    private func persistentTaskDirectory(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HLSDownloadTasks", isDirectory: true)
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    private func cachedSegmentURL(index: Int, directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "segment-%06d.bin", index))
    }

    private func cachedStatusURL(index: Int, directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "segment-%06d.status", index))
    }

    private func downloadSegmentToCache(
        _ segment: HLSSegment, index: Int, directory: URL, cookies: [HTTPCookie]
    ) async throws -> (Int, Int) {
        let destination = cachedSegmentURL(index: index, directory: directory)
        let statusFile = cachedStatusURL(index: index, directory: directory)
        if FileManager.default.fileExists(atPath: destination.path),
           let raw = try? String(contentsOf: statusFile, encoding: .utf8),
           let status = Int(raw) {
            return (index, status)
        }

        var lastError: Error = HLSDownloadError.invalidResponse
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                let temp = try await fetchTemporaryFile(segment.url, range: segment.byteRange, cookies: cookies)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp.fileURL, to: destination)
                try String(temp.statusCode).write(to: statusFile, atomically: true, encoding: .utf8)
                return (index, temp.statusCode)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(attempt))
                }
            }
        }
        throw lastError
    }

    private func remuxTransportStream(_ sourceURL: URL, discontinuityOffsets: [UInt64]) async throws -> URL {
        let destination = sourceURL.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: destination)
        do {
            let boundaries = Array(Set(discontinuityOffsets)).sorted()
            if boundaries.isEmpty {
                let remuxer = VLCTSRemuxer()
                let result = try await remuxer.remux(source: sourceURL, destination: destination)
                try await Self.validateRemuxedVideo(result)
                try? FileManager.default.removeItem(at: sourceURL)
                return result
            }

            status = "检测到时间线断点，正在分段转封装…"
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HLSRemux-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let chunks = try Self.splitTransportStream(sourceURL, boundaries: boundaries, into: temporaryDirectory)
            var chunkMP4s: [URL] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                status = "分段转封装：\(index + 1)/\(chunks.count)"
                let partMP4 = temporaryDirectory.appendingPathComponent("part-\(index + 1).mp4")
                let remuxer = VLCTSRemuxer()
                let converted = try await remuxer.remux(source: chunk, destination: partMP4)
                try await Self.validateRemuxedVideo(converted)
                chunkMP4s.append(converted)
            }

            status = "正在合并 MP4 时间线…"
            try await Self.mergeMP4Segments(chunkMP4s, destination: destination)
            try await Self.validateRemuxedVideo(destination)
            try? FileManager.default.removeItem(at: sourceURL)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func splitTransportStream(_ sourceURL: URL, boundaries: [UInt64], into directory: URL) throws -> [URL] {
        let size = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let validBoundaries = boundaries.filter { $0 > 0 && $0 < size }
        let offsets = [UInt64(0)] + validBoundaries + [size]
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var chunks: [URL] = []

        for index in 0..<(offsets.count - 1) {
            let start = offsets[index]
            var remaining = offsets[index + 1] - start
            guard remaining > 0 else { continue }
            let destination = directory.appendingPathComponent("part-\(index + 1).ts")
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw HLSDownloadError.invalidResponse
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try input.seek(toOffset: start)
            while remaining > 0 {
                let amount = Int(min(UInt64(1024 * 1024), remaining))
                let data = try input.read(upToCount: amount) ?? Data()
                guard !data.isEmpty else { throw HLSDownloadError.invalidRange }
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
            try output.synchronize()
            chunks.append(destination)
        }
        guard chunks.count > 1 else { throw HLSDownloadError.invalidRange }
        return chunks
    }

    private static func mergeMP4Segments(_ segments: [URL], destination: URL) async throws {
        guard !segments.isEmpty else { throw HLSDownloadError.emptyDownload }
        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw HLSDownloadError.invalidResponse }
        let audioCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var cursor = CMTime.zero

        for segmentURL in segments {
            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = sourceVideoTracks.first else {
                throw NSError(domain: "HLSRemux", code: 10, userInfo: [NSLocalizedDescriptionKey: "分段 MP4 缺少视频轨道"])
            }
            let videoRange = try await sourceVideoTrack.load(.timeRange)
            try videoCompositionTrack.insertTimeRange(videoRange, of: sourceVideoTrack, at: cursor)

            if let audioCompositionTrack {
                let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
                if let sourceAudioTrack = sourceAudioTracks.first {
                    let audioRange = try await sourceAudioTrack.load(.timeRange)
                    try audioCompositionTrack.insertTimeRange(audioRange, of: sourceAudioTrack, at: cursor)
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        try? FileManager.default.removeItem(at: destination)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw HLSDownloadError.invalidResponse
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exporter.error ?? NSError(
                        domain: "HLSRemux",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "分段 MP4 合并失败"]
                    ))
                default:
                    continuation.resume(throwing: NSError(
                        domain: "HLSRemux",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "MP4 合并未正常完成"]
                    ))
                }
            }
        }
    }

    private static func validateRemuxedVideo(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw NSError(domain: "HLSRemuxValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "转换结果没有视频轨道"])
        }
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoRange = try await videoTrack.load(.timeRange)
        let videoDuration = CMTimeGetSeconds(videoRange.duration)
        guard assetDuration.isFinite, videoDuration.isFinite, assetDuration > 0,
              videoDuration >= assetDuration * 0.90 else {
            throw NSError(domain: "HLSRemuxValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "视频轨道时长明显短于文件总时长（视频 \(Int(max(0, videoDuration))) 秒 / 文件 \(Int(max(0, assetDuration))) 秒）"])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "HLSRemuxValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法建立视频解码读取器"])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "HLSRemuxValidation", code: 4, userInfo: [NSLocalizedDescriptionKey: "视频解码器无法启动"])
        }
        var decodedFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
               CVPixelBufferGetWidth(pixelBuffer) > 0,
               CVPixelBufferGetHeight(pixelBuffer) > 0 {
                decodedFrames += 1
            }
        }
        guard decodedFrames > 0 else {
            let detail = reader.error?.localizedDescription ?? "未能解码出有效画面帧"
            throw NSError(domain: "HLSRemuxValidation", code: 5, userInfo: [NSLocalizedDescriptionKey: "MP4 视频轨道存在但画面解码失败：\(detail)"])
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "HLSRemuxValidation", code: 6, userInfo: [NSLocalizedDescriptionKey: "MP4 全片解码校验失败"])
        }
    }

    private func fetchText(_ url: URL, cookies: [HTTPCookie]) async throws -> (text: String, finalURL: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyCookies(cookies, for: url, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw HLSDownloadError.invalidResponse }
        return (text, http.url ?? url)
    }

    private func fetchKey(_ key: HLSKey, cookies: [HTTPCookie]) async throws -> Data {
        guard let url = key.url else { throw HLSDownloadError.unsupportedEncryption }
        if let cached = keyCache[url] { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyCookies(cookies, for: url, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        guard data.count == kCCKeySizeAES128 else { throw HLSDownloadError.invalidKey }
        keyCache[url] = data
        return data
    }

    private func fetchTemporaryFile(_ url: URL, range: HLSByteRange?, cookies: [HTTPCookie]) async throws -> (fileURL: URL, statusCode: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        applyCookies(cookies, for: url, to: &request)
        if let range {
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
        let (fileURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        if range != nil && http.statusCode != 200 && http.statusCode != 206 {
            throw HLSDownloadError.invalidRange
        }
        return (fileURL, http.statusCode)
    }

    nonisolated private static func appendDownloadedFile(_ item: (fileURL: URL, statusCode: Int), range: HLSByteRange?, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: item.fileURL)
        defer { try? input.close() }

        var remaining: Int64?
        if let range {
            if item.statusCode == 200 {
                try input.seek(toOffset: UInt64(range.offset))
            }
            remaining = range.length
        }

        while true {
            let requested = remaining.map { Int(min(Int64(1024 * 1024), $0)) } ?? (1024 * 1024)
            if requested == 0 { break }
            let chunk = try input.read(upToCount: requested) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            if let count = remaining {
                remaining = count - Int64(chunk.count)
            }
        }
        if let remaining, remaining != 0 { throw HLSDownloadError.invalidRange }
    }

    nonisolated private static func readDownloadedBytes(_ item: (fileURL: URL, statusCode: Int), range: HLSByteRange?) throws -> Data {
        let input = try FileHandle(forReadingFrom: item.fileURL)
        defer { try? input.close() }
        if let range {
            if item.statusCode == 200 { try input.seek(toOffset: UInt64(range.offset)) }
            guard let data = try input.read(upToCount: Int(range.length)), data.count == Int(range.length) else {
                throw HLSDownloadError.invalidRange
            }
            return data
        }
        return try Data(contentsOf: item.fileURL, options: [.mappedIfSafe])
    }


    private func applyCookies(_ cookies: [HTTPCookie], for url: URL, to request: inout URLRequest) {
        guard let host = url.host?.lowercased() else { return }
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            let pathMatches = url.path.hasPrefix(cookie.path)
            let secureMatches = !cookie.isSecure || url.scheme?.lowercased() == "https"
            return domainMatches && pathMatches && secureMatches
        }
        if let cookieHeader = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    nonisolated private static func sequenceIV(_ sequence: Int) -> Data {
        var value = UInt64(max(0, sequence)).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &value) { raw in
            bytes.replaceSubrange(8..<16, with: raw)
        }
        return Data(bytes)
    }

    nonisolated private static func decryptAES128(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw HLSDownloadError.invalidKey
        }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved: size_t = 0
        let outputCapacity = output.count
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSDownloadError.invalidResponse }
        return Data(output.prefix(Int(moved)))
    }
}
