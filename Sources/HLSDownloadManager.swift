import Foundation
import Combine
import CommonCrypto

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

    private var keyCache: [URL: Data] = [:]

    func start(url: URL) async throws -> URL {
        guard !isDownloading else { throw HLSDownloadError.unsupportedPlaylist }
        isDownloading = true
        progress = 0
        outputURL = nil
        status = "读取播放列表…"
        defer { isDownloading = false }

        var playlistURL = url
        var playlist: HLSPlaylist?
        for _ in 0..<4 {
            let text = try await fetchText(playlistURL)
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
        let filename = "HLS-\(Date().formatted(.iso8601.year().month().day().timeZone(.gmt).time(includingFractionalSeconds: false))).\(ext)"
            .replacingOccurrences(of: ":", with: "-")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw HLSDownloadError.invalidResponse
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var lastMap: HLSMap?
        let total = mediaPlaylist.segments.count

        for (index, segment) in mediaPlaylist.segments.enumerated() {
            status = "下载分片 \(index + 1)/\(total)"
            if let map = segment.map, map != lastMap {
                let mapTemp = try await fetchTemporaryFile(map.url, range: map.byteRange)
                deferRemove(mapTemp.fileURL)
                if let key = segment.key, key.method == "AES-128" {
                    guard let iv = key.iv else { throw HLSDownloadError.unsupportedEncryption }
                    let keyData = try await fetchKey(key)
                    let bytes = try readDownloadedBytes(mapTemp, range: map.byteRange)
                    let clear = try decryptAES128(bytes, key: keyData, iv: iv)
                    try output.write(contentsOf: clear)
                } else {
                    try appendDownloadedFile(mapTemp, range: map.byteRange, to: output)
                }
                lastMap = map
            }

            let temp = try await fetchTemporaryFile(segment.url, range: segment.byteRange)
            deferRemove(temp.fileURL)
            if let key = segment.key {
                guard key.method == "AES-128", key.keyFormat == "identity", let keyURL = key.url else {
                    throw HLSDownloadError.unsupportedEncryption
                }
                let keyData = try await fetchKey(key)
                let iv = key.iv ?? sequenceIV(segment.sequence)
                let encrypted = try readDownloadedBytes(temp, range: segment.byteRange)
                let clear = try decryptAES128(encrypted, key: keyData, iv: iv)
                try output.write(contentsOf: clear)
            } else {
                try appendDownloadedFile(temp, range: segment.byteRange, to: output)
            }

            progress = Double(index + 1) / Double(total)
        }

        try output.synchronize()
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw HLSDownloadError.emptyDownload
        }
        outputURL = destination
        status = "下载完成"
        return destination
    }

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw HLSDownloadError.invalidResponse }
        return text
    }

    private func fetchKey(_ key: HLSKey) async throws -> Data {
        guard let url = key.url else { throw HLSDownloadError.unsupportedEncryption }
        if let cached = keyCache[url] { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HLSDownloadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HLSDownloadError.httpStatus(http.statusCode) }
        guard data.count == kCCKeySizeAES128 else { throw HLSDownloadError.invalidKey }
        keyCache[url] = data
        return data
    }

    private func fetchTemporaryFile(_ url: URL, range: HLSByteRange?) async throws -> (fileURL: URL, statusCode: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
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

    private func deferRemove(_ url: URL) {
        // Temporary downloads are removed immediately after their segment has been appended.
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
        var moved = 0
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
                            output.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSDownloadError.invalidResponse }
        return Data(output.prefix(moved))
    }
}
