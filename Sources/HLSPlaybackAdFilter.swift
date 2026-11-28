import Foundation
import CryptoKit

enum HLSPlaybackAdFilter {
    struct Result {
        let playlistURL: URL
        let removedSegmentCount: Int
    }

    static func prepare(url: URL, headers: [String: String] = [:]) async throws -> Result? {
        var playlistURL = url
        var playlistText = ""
        var parsed: HLSPlaylist?

        for _ in 0..<3 {
            var request = URLRequest(url: playlistURL)
            request.timeoutInterval = 12
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                throw HLSParserError.invalidURL
            }
            playlistText = text
            let finalURL = http.url ?? playlistURL
            let current = try HLSParser.parse(text, baseURL: finalURL)
            if let variant = current.variants.first {
                playlistURL = variant.url
                continue
            }
            playlistURL = finalURL
            parsed = current
            break
        }

        guard let parsed, parsed.isEndList else { return nil }
        let adURLs = Set(parsed.segments.filter(\.isAd).map { $0.url.absoluteString })
        guard !adURLs.isEmpty else { return nil }

        let lines = playlistText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var output: [String] = []
        let firstRetainedSequence = parsed.segments.first(where: { !$0.isAd })?.sequence ?? parsed.mediaSequence
        var pendingSegmentTags: [String] = []
        var carryDiscontinuity = false
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                pendingSegmentTags.append(line)
            } else if !line.hasPrefix("#") {
                guard let absoluteURL = URL(string: line, relativeTo: playlistURL)?.absoluteURL else {
                    throw HLSParserError.invalidURL
                }
                if !adURLs.contains(absoluteURL.absoluteString) {
                    if carryDiscontinuity && !pendingSegmentTags.contains("#EXT-X-DISCONTINUITY") {
                        output.append("#EXT-X-DISCONTINUITY")
                    }
                    output.append(contentsOf: pendingSegmentTags)
                    output.append(absoluteURL.absoluteString)
                    carryDiscontinuity = false
                } else if pendingSegmentTags.contains("#EXT-X-DISCONTINUITY") {
                    carryDiscontinuity = true
                }
                pendingSegmentTags.removeAll(keepingCapacity: true)
            } else if isSegmentScopedTag(line) {
                pendingSegmentTags.append(line)
            } else if isAdDateRange(line) {
                continue
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                output.append("#EXT-X-MEDIA-SEQUENCE:\(firstRetainedSequence)")
            } else {
                output.append(rewriteURIAttributes(in: line, relativeTo: playlistURL))
            }
        }

        guard output.contains(where: { !$0.hasPrefix("#") }) else {
            throw HLSParserError.emptyPlaylist
        }
        let removedCount = parsed.segments.filter(\.isAd).count
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HLSFilteredPlaylists", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data((url.absoluteString + output.joined(separator: "\n")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(digest + ".m3u8")
        try (output.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        return Result(playlistURL: destination, removedSegmentCount: removedCount)
    }

    private static func isSegmentScopedTag(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-BYTERANGE:") ||
        line == "#EXT-X-DISCONTINUITY" ||
        line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") ||
        line == "#EXT-X-GAP" ||
        line.hasPrefix("#EXT-X-CUE-OUT") ||
        line.hasPrefix("#EXT-X-CUE-IN") ||
        line.hasPrefix("#EXT-X-SCTE35-OUT:") ||
        line.hasPrefix("#EXT-X-SCTE35-IN:")
    }

    private static func isAdDateRange(_ line: String) -> Bool {
        guard line.hasPrefix("#EXT-X-DATERANGE:") else { return false }
        let value = line.lowercased()
        return value.contains("class=\"ad") ||
            value.contains("interstitial") ||
            value.contains("scte35-out") ||
            value.contains("splice")
    }

    private static func rewriteURIAttributes(in line: String, relativeTo baseURL: URL) -> String {
        guard line.contains("URI=\""),
              let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
        var result = line
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: result),
                  let absolute = URL(string: String(result[range]), relativeTo: baseURL)?.absoluteURL else { continue }
            result.replaceSubrange(range, with: absolute.absoluteString)
        }
        return result
    }
}
