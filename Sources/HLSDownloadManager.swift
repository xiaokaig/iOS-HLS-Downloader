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

    func inspectPlaylist(_ url: URL, cookies: [HTTPCookie] = []) async throws -> HLSInspection {
        status = "解析播放列表…"
        let text = try await fetchText(url, cookies: cookies)
        let parsed = try HLSParser.parse(text, baseURL: url)
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

    func start(url: URL, cookies: [HTTPCookie] = []) async throws -> URL {
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
            let text = try await fetchText(playlistURL, cookies: cookies)
            let parsed = try HLSParser.parse(text, baseURL: playlistURL)
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

        let hasMap = mediaPlaylist.segments.contains { $0.map != nil }
        let ext = hasMap ? "mp4" : "ts"
        let filename = "HLS-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw HLSDownloadError.invalidResponse
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let total = mediaPlaylist.segments.count
        let taskDirectory = persistentTaskDirectory(for: playlistURL)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        var signatureLines: [String] = []
        signatureLines.reserveCapacity(mediaPlaylist.segments.count)
        for segment in mediaPlaylist.segments {
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
                let segment = mediaPlaylist.segments[index]
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
                    let segment = mediaPlaylist.segments[index]
                    group.addTask {
                        try await self.downloadSegmentToCache(
                            segment, index: index, directory: taskDirectory, cookies: cookies
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        status = "按顺序组装视频…"
        var lastMap: HLSMap?
        for (index, segment) in mediaPlaylist.segments.enumerated() {
            if let map = segment.map, map != lastMap {
                let mapTemp = try await fetchTemporaryFile(map.url, range: map.byteRange, cookies: cookies)
                defer { try? FileManager.default.removeItem(at: mapTemp.fileURL) }
                if let key = segment.key {
                    guard key.method == "AES-128", key.keyFormat == "identity", key.iv != nil else {
                        throw HLSDownloadError.unsupportedEncryption
                    }
                    let keyData = try await fetchKey(key, cookies: cookies)
                    let bytes = try readDownloadedBytes(mapTemp, range: map.byteRange)
                    let clear = try decryptAES128(bytes, key: keyData, iv: key.iv!)
                    try output.write(contentsOf: clear)
                } else {
                    try appendDownloadedFile(mapTemp, range: map.byteRange, to: output)
                }
                lastMap = map
            }

            let cached = cachedSegmentURL(index: index, directory: taskDirectory)
            let statusCode = (try? String(contentsOf: cachedStatusURL(index: index, directory: taskDirectory), encoding: .utf8))
                .flatMap(Int.init) ?? 200
            let item = (fileURL: cached, statusCode: statusCode)
            if let key = segment.key {
                guard key.method == "AES-128", key.keyFormat == "identity", key.url != nil else {
                    throw HLSDownloadError.unsupportedEncryption
                }
                let keyData = try await fetchKey(key, cookies: cookies)
                let iv = key.iv ?? sequenceIV(segment.sequence)
                let encrypted = try readDownloadedBytes(item, range: segment.byteRange)
                let clear = try decryptAES128(encrypted, key: keyData, iv: iv)
                try output.write(contentsOf: clear)
            } else {
                try appendDownloadedFile(item, range: segment.byteRange, to: output)
            }
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
            status = "正在尝试 MP4 转封装…"
            do {
                finalURL = try await remuxTransportStream(destination)
            } catch {
                // Keep the valid TS file; never disguise it with an .mp4 extension.
                conversionWarning = "MP4 转换失败，已保留 TS 文件：\(error.localizedDescription)"
            }
        }
        outputURL = finalURL
        try? FileManager.default.removeItem(at: taskDirectory)
        if finalURL.pathExtension.lowercased() == "mp4" {
            status = "下载完成（MP4）"
        } else if conversionWarning != nil {
            status = "下载完成（TS，MP4 转换失败）"
        } else {
            status = "下载完成（TS）"
        }
        return finalURL
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
            do {
                let temp = try await fetchTemporaryFile(segment.url, range: segment.byteRange, cookies: cookies)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp.fileURL, to: destination)
                try String(temp.statusCode).write(to: statusFile, atomically: true, encoding: .utf8)
                return (index, temp.statusCode)
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(attempt))
                }
            }
        }
        throw lastError
    }

    private func remuxTransportStream(_ sourceURL: URL) async throws -> URL {
        let destination = sourceURL.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: destination)
        do {
            let remuxer = VLCTSRemuxer()
            let result = try await remuxer.remux(source: sourceURL, destination: destination)
            try? FileManager.default.removeItem(at: sourceURL)
            return result
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func fetchText(_ url: URL, cookies: [HTTPCookie]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyCookies(cookies, for: url, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw HLSDownloadError.invalidResponse }
        return text
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

    private func appendDownloadedFile(_ item: (fileURL: URL, statusCode: Int), range: HLSByteRange?, to output: FileHandle) throws {
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

    private func readDownloadedBytes(_ item: (fileURL: URL, statusCode: Int), range: HLSByteRange?) throws -> Data {
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

    private func sequenceIV(_ sequence: Int) -> Data {
        var value = UInt64(max(0, sequence)).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &value) { raw in
            bytes.replaceSubrange(8..<16, with: raw)
        }
        return Data(bytes)
    }

    private func decryptAES128(_ input: Data, key: Data, iv: Data) throws -> Data {
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
