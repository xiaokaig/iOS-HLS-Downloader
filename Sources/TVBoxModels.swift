import Foundation

struct TVBoxSite: Identifiable, Hashable {
    let id: String
    let name: String
    let api: String
    let type: Int
    let searchable: Bool
    let extDescription: String

    var typeName: String {
        switch type {
        case 0: return "XML CMS"
        case 1: return "JSON CMS"
        case 3: return "Spider"
        case 4: return "扩展 API"
        default: return "未知类型（\(type)）"
        }
    }

    var compatibilityDescription: String {
        switch type {
        case 0, 1: return "支持标准 CMS 搜索、详情与直链播放"
        case 3: return "暂不执行 Spider"
        case 4: return "暂不执行扩展 API"
        default: return "暂不支持此类型"
        }
    }
}

struct TVBoxParsedSource {
    let title: String
    let siteCount: Int
    let sites: [TVBoxSite]
    let parseCount: Int
    let liveCount: Int
    let spiderReference: String?
}

struct TVBoxVideo: Identifiable, Hashable {
    let id: String
    let name: String
    let imageURL: String
    let remarks: String
    let content: String
}

struct TVBoxEpisode: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
}

struct TVBoxPlaySource: Identifiable, Hashable {
    let id: String
    let name: String
    let episodes: [TVBoxEpisode]
}

struct TVBoxVideoDetail {
    let video: TVBoxVideo
    let playSources: [TVBoxPlaySource]
}

enum TVBoxSourceError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case responseTooLarge
    case invalidJSON
    case missingSites
    case unsupportedSite
    case emptyKeyword
    case invalidResponse
    case noPlayableAddress

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTP 或 HTTPS JSON 源地址。"
        case .httpStatus(let code): return "站点返回 HTTP \(code)。"
        case .responseTooLarge: return "源文件或接口响应超过 10 MB，已停止读取。"
        case .invalidJSON: return "响应不是有效的 JSON 或 XML CMS 数据。"
        case .missingSites: return "JSON 中没有找到 sites 站点列表。"
        case .unsupportedSite: return "该站点类型暂不支持搜索，请选择 XML CMS 或 JSON CMS 站点。"
        case .emptyKeyword: return "请输入要搜索的影视名称。"
        case .invalidResponse: return "站点没有返回可识别的影视列表。"
        case .noPlayableAddress: return "该集没有可直接播放的 HTTP/HTTPS 地址。"
        }
    }
}

enum TVBoxSourceParser {
    static func parse(_ data: Data, baseURL: URL) throws -> TVBoxParsedSource {
        guard data.count <= 10 * 1024 * 1024 else { throw TVBoxSourceError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVBoxSourceError.invalidJSON
        }
        guard let rawSites = root["sites"] as? [[String: Any]] else {
            throw TVBoxSourceError.missingSites
        }
        let sites = rawSites.enumerated().map { index, raw -> TVBoxSite in
            let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let api = (raw["api"] as? String) ?? ""
            let type = (raw["type"] as? Int) ?? Int((raw["type"] as? String) ?? "") ?? -1
            let key = (raw["key"] as? String) ?? (raw["id"] as? String) ?? "\(index)-\(name ?? "site")"
            let resolvedAPI = api.isEmpty ? "" : (URL(string: api, relativeTo: baseURL)?.absoluteURL.absoluteString ?? api)
            let ext = raw["ext"] as? String
            return TVBoxSite(
                id: key,
                name: (name?.isEmpty == false ? name! : "未命名站点"),
                api: resolvedAPI,
                type: type,
                searchable: (raw["searchable"] as? Bool) ?? true,
                extDescription: ext.map { String($0.prefix(120)) } ?? ""
            )
        }
        return TVBoxParsedSource(
            title: (root["name"] as? String) ?? baseURL.host ?? "TVBox 源",
            siteCount: sites.count,
            sites: sites,
            parseCount: (root["parses"] as? [[String: Any]])?.count ?? 0,
            liveCount: (root["lives"] as? [[String: Any]])?.count ?? 0,
            spiderReference: root["spider"] as? String
        )
    }

    static func fetch(_ address: String) async throws -> (TVBoxParsedSource, URL) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw TVBoxSourceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVBoxSourceError.invalidJSON }
        guard (200..<300).contains(http.statusCode) else { throw TVBoxSourceError.httpStatus(http.statusCode) }
        return (try parse(data, baseURL: http.url ?? url), http.url ?? url)
    }
}

enum TVBoxAPIClient {
    static func search(site: TVBoxSite, keyword: String, page: Int = 1) async throws -> [TVBoxVideo] {
        guard site.type == 0 || site.type == 1 else { throw TVBoxSourceError.unsupportedSite }
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw TVBoxSourceError.emptyKeyword }
        let data = try await request(site: site, parameters: [("ac", "videolist"), ("wd", term), ("pg", String(max(1, page)))])
        return try decodeVideos(data)
    }

    static func detail(site: TVBoxSite, video: TVBoxVideo) async throws -> TVBoxVideoDetail {
        guard site.type == 0 || site.type == 1 else { throw TVBoxSourceError.unsupportedSite }
        let data = try await request(site: site, parameters: [("ac", "detail"), ("ids", video.id)])
        let records = try decodeRecords(data)
        guard let record = records.first else { throw TVBoxSourceError.invalidResponse }
        let resolvedVideo = makeVideo(record) ?? video
        let from = string(record, keys: ["vod_play_from", "play_from", "vod_playfrom"])
        let rawURLs = string(record, keys: ["vod_play_url", "play_url", "vod_playurl"])
        let sourceNames = from.components(separatedBy: "$$$")
        let sourceLists = rawURLs.components(separatedBy: "$$$")
        let sources = sourceLists.enumerated().map { index, raw -> TVBoxPlaySource in
            let name = index < sourceNames.count && !sourceNames[index].isEmpty ? sourceNames[index] : "线路 \(index + 1)"
            let episodes = raw.components(separatedBy: "#").enumerated().compactMap { episodeIndex, item -> TVBoxEpisode? in
                let parts = item.components(separatedBy: "$")
                guard let address = parts.last, address.contains("://") else { return nil }
                let episodeName = parts.count > 1 ? parts.dropLast().joined(separator: "$") : "第 \(episodeIndex + 1) 集"
                return TVBoxEpisode(id: "\(index)-\(episodeIndex)-\(address)", name: episodeName, url: address)
            }
            return TVBoxPlaySource(id: "\(index)-\(name)", name: name, episodes: episodes)
        }.filter { !$0.episodes.isEmpty }
        return TVBoxVideoDetail(video: resolvedVideo, playSources: sources)
    }

    private static func request(site: TVBoxSite, parameters: [(String, String)]) async throws -> Data {
        guard var components = URLComponents(string: site.api),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw TVBoxSourceError.invalidURL }
        let replacedNames = Set(parameters.map { $0.0 })
        let retained = (components.queryItems ?? []).filter { !replacedNames.contains($0.name) }
        components.queryItems = retained + parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw TVBoxSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json, text/xml, application/xml, */*", forHTTPHeaderField: "Accept")
        request.setValue("HLSDownloader/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVBoxSourceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TVBoxSourceError.httpStatus(http.statusCode) }
        guard data.count <= 10 * 1024 * 1024 else { throw TVBoxSourceError.responseTooLarge }
        return data
    }

    private static func decodeVideos(_ data: Data) throws -> [TVBoxVideo] {
        try decodeRecords(data).compactMap(makeVideo)
    }

    private static func decodeRecords(_ data: Data) throws -> [[String: String]] {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let records = jsonRecords(object), !records.isEmpty {
            return records.map { item in
                var result: [String: String] = [:]
                for (key, value) in item { result[key.lowercased()] = stringValue(value) }
                return result
            }
        }
        let parser = TVBoxXMLVideoParser(data: data)
        if let records = parser.parse(), !records.isEmpty { return records }
        throw TVBoxSourceError.invalidResponse
    }

    private static func jsonRecords(_ object: Any) -> [[String: Any]]? {
        if let root = object as? [String: Any] {
            if let list = root["list"] as? [[String: Any]], !list.isEmpty { return list }
            if let data = root["data"] as? [String: Any],
               let list = data["list"] as? [[String: Any]], !list.isEmpty { return list }
            if let data = root["data"] as? [[String: Any]], !data.isEmpty { return data }
            if root["vod_id"] != nil || root["id"] != nil { return [root] }
        }
        if let array = object as? [[String: Any]], !array.isEmpty { return array }
        return nil
    }

    private static func makeVideo(_ record: [String: String]) -> TVBoxVideo? {
        let id = string(record, keys: ["vod_id", "id", "video_id"])
        let name = string(record, keys: ["vod_name", "name", "title"])
        guard !id.isEmpty || !name.isEmpty else { return nil }
        return TVBoxVideo(
            id: id.isEmpty ? name : id,
            name: name.isEmpty ? "未命名影视" : name,
            imageURL: string(record, keys: ["vod_pic", "pic", "cover", "image"]),
            remarks: string(record, keys: ["vod_remarks", "remarks", "note", "state"]),
            content: string(record, keys: ["vod_content", "content", "description", "des"])
        )
    }

    private static func string(_ record: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = record[key], !value.isEmpty { return value }
        }
        return ""
    }

    private static func stringValue(_ value: Any) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}

private final class TVBoxXMLVideoParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var records: [[String: String]] = []
    private var current: [String: String]?
    private var currentKey: String?
    private var text = ""

    init(data: Data) { self.data = data }

    func parse() -> [[String: String]]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? records : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let key = elementName.lowercased()
        if key == "video" { current = [:] }
        if current != nil {
            currentKey = key
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentKey != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if currentKey != nil, let value = String(data: CDATABlock, encoding: .utf8) {
            text += value
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let key = elementName.lowercased()
        if key == "video", let current {
            records.append(current)
            self.current = nil
            currentKey = nil
            text = ""
            return
        }
        if current != nil, let currentKey {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, var record = current {
                record[currentKey] = value
                current = record
            }
        }
        currentKey = nil
        text = ""
    }
}
