import Foundation

enum HLSParserError: LocalizedError {
    case invalidURL
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "播放列表包含无效的媒体地址"
        case .emptyPlaylist: return "播放列表为空或没有可下载的分片"
        }
    }
}

enum HLSParser {
    static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let normalizedText = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = normalizedText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first(where: { !$0.isEmpty }) == "#EXTM3U" else { throw HLSParserError.emptyPlaylist }

        var variants: [HLSVariant] = []
        var segments: [HLSSegment] = []
        var pendingVariant: [String: String]?
        var pendingDuration = 0.0
        var pendingRange: String?
        var currentKey: HLSKey?
        var currentMap: HLSMap?
        var mediaSequence = 0
        var nextSequence = 0
        var rangeEnds: [String: Int64] = [:]
        var isEndList = false
        var pendingDiscontinuity = false
        var isAdBreak = false
        var adBreakRemaining: Double?

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                nextSequence = mediaSequence
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)))
                if let rawURL = attrs["URI"], let variantURL = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL {
                    let bandwidth = Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0") ?? 0
                    variants.append(HLSVariant(url: variantURL, bandwidth: bandwidth, resolution: attrs["RESOLUTION"]))
                }
            } else if line.hasPrefix("#EXTINF:") {
                let raw = String(line.dropFirst("#EXTINF:".count)).components(separatedBy: ",").first ?? "0"
                pendingDuration = Double(raw) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    currentKey = nil
                } else {
                    let keyURL = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                    let keyFormat = attrs["KEYFORMAT"] ?? "identity"
                    currentKey = HLSKey(method: method, url: keyURL, iv: attrs["IV"].flatMap(parseIV), keyFormat: keyFormat)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let rawURL = attrs["URI"], let mapURL = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL else {
                    throw HLSParserError.invalidURL
                }
                let range = attrs["BYTERANGE"].flatMap { parseRange($0, uri: mapURL.absoluteString, ends: &rangeEnds) }
                currentMap = HLSMap(url: mapURL, byteRange: range)
            } else if line.hasPrefix("#EXT-X-CUE-OUT") || line.hasPrefix("#EXT-X-SCTE35-OUT:") {
                isAdBreak = true
                let raw = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                let durationToken = raw.split(separator: ",").first.map(String.init) ?? ""
                adBreakRemaining = Double(durationToken)
            } else if line.hasPrefix("#EXT-X-CUE-IN") || line.hasPrefix("#EXT-X-SCTE35-IN:") {
                isAdBreak = false
                adBreakRemaining = nil
            } else if line.hasPrefix("#EXT-X-DATERANGE:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-DATERANGE:".count)))
                let marker = ((attrs["CLASS"] ?? "") + " " + (attrs["SCTE35-OUT"] ?? "")).lowercased()
                if marker.contains("ad") || marker.contains("interstitial") || marker.contains("splice") || attrs["SCTE35-OUT"] != nil {
                    isAdBreak = true
                    adBreakRemaining = Double(attrs["DURATION"] ?? "")
                }
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line == "#EXT-X-ENDLIST" {
                isEndList = true
            } else if !line.hasPrefix("#") {
                guard let mediaURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                    throw HLSParserError.invalidURL
                }
                if let attrs = pendingVariant {
                    let bandwidth = Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0") ?? 0
                    variants.append(HLSVariant(
                        url: mediaURL,
                        bandwidth: bandwidth,
                        resolution: attrs["RESOLUTION"]
                    ))
                    pendingVariant = nil
                    continue
                }

                let range = pendingRange.flatMap { parseRange($0, uri: mediaURL.absoluteString, ends: &rangeEnds) }
                segments.append(HLSSegment(
                    id: segments.count,
                    sequence: nextSequence,
                    url: mediaURL,
                    duration: pendingDuration,
                    byteRange: range,
                    key: currentKey,
                    map: currentMap,
                    startsDiscontinuity: pendingDiscontinuity,
                    isAd: isAdBreak
                ))
                if let remaining = adBreakRemaining {
                    let nextRemaining = max(0, remaining - pendingDuration)
                    adBreakRemaining = nextRemaining
                    if nextRemaining <= 0 { isAdBreak = false; adBreakRemaining = nil }
                }
                nextSequence += 1
                pendingDuration = 0
                pendingRange = nil
                pendingDiscontinuity = false
            }
        }

        if !variants.isEmpty {
            return HLSPlaylist(variants: variants.sorted { $0.bandwidth > $1.bandwidth }, segments: [], mediaSequence: mediaSequence, isEndList: isEndList)
        }
        guard !segments.isEmpty else { throw HLSParserError.emptyPlaylist }
        let markedSegments = markLikelyLeadingAdSegments(segments)
        return HLSPlaylist(variants: [], segments: markedSegments, mediaSequence: mediaSequence, isEndList: isEndList)
    }

    private static func markLikelyLeadingAdSegments(_ segments: [HLSSegment]) -> [HLSSegment] {
        let adTokens = ["advert", "/ad/", "/ads/", "preroll", "pre-roll", "vast", "commercial", "promo"]
        let explicitlyMarked = segments.map { segment in
            let address = segment.url.absoluteString.lowercased()
            return segment.isAd || adTokens.contains(where: { address.contains($0) })
        }

        // Some providers put the pre-roll on a separate CDN and omit HLS ad
        // markers. Only infer a leading ad block when one CDN serves at least
        // 80% of the playlist and the alternate-CDN block is at the very start.
        let hostCounts = Dictionary(grouping: segments, by: { $0.url.host?.lowercased() ?? "" })
            .mapValues(\.count)
        guard let dominantHost = hostCounts.max(by: { $0.value < $1.value })?.key,
              !dominantHost.isEmpty,
              Double(hostCounts[dominantHost] ?? 0) / Double(segments.count) >= 0.8,
              segments.first?.url.host?.lowercased() != dominantHost else {
            return segments.enumerated().map { index, segment in
                HLSSegment(id: segment.id, sequence: segment.sequence, url: segment.url,
                           duration: segment.duration, byteRange: segment.byteRange, key: segment.key,
                           map: segment.map, startsDiscontinuity: segment.startsDiscontinuity,
                           isAd: explicitlyMarked[index])
            }
        }

        var leadingAlternateIndices = Set<Int>()
        var leadingDuration = 0.0
        for (index, segment) in segments.enumerated() {
            if segment.url.host?.lowercased() == dominantHost { break }
            guard segment.duration > 0, segment.duration <= 30 else { break }
            leadingAlternateIndices.insert(index)
            leadingDuration += segment.duration
            if leadingDuration > 60 { leadingAlternateIndices.removeAll(); break }
        }

        return segments.enumerated().map { index, segment in
            HLSSegment(id: segment.id, sequence: segment.sequence, url: segment.url,
                       duration: segment.duration, byteRange: segment.byteRange, key: segment.key,
                       map: segment.map, startsDiscontinuity: segment.startsDiscontinuity,
                       isAd: explicitlyMarked[index] || leadingAlternateIndices.contains(index))
        }
    }

    private static func attributes(_ source: String) -> [String: String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in source {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }

        var result: [String: String] = [:]
        for part in parts {
            guard let equal = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equal]).trimmingCharacters(in: .whitespaces)
            var value = String(part[part.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func parseRange(_ raw: String, uri: String, ends: inout [String: Int64]) -> HLSByteRange? {
        let values = raw.split(separator: "@", maxSplits: 1).compactMap { Int64($0) }
        guard let length = values.first, length > 0 else { return nil }
        let offset = values.count > 1 ? values[1] : (ends[uri] ?? 0)
        guard offset >= 0 else { return nil }
        ends[uri] = offset + length
        return HLSByteRange(length: length, offset: offset)
    }

    private static func parseIV(_ raw: String) -> Data? {
        var hex = raw.lowercased().replacingOccurrences(of: "0x", with: "")
        if hex.count > 32 { hex = String(hex.suffix(32)) }
        if hex.count % 2 == 1 { hex = "0" + hex }
        if hex.count < 32 { hex = String(repeating: "0", count: 32 - hex.count) + hex }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return Data(bytes)
    }
}
