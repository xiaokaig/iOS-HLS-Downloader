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
        case 0: return "XML API"
        case 1: return "JSON CMS"
        case 3: return "Spider"
        case 4: return "扩展 API"
        default: return "未知类型（\(type)）"
        }
    }

    var compatibilityDescription: String {
        switch type {
        case 0, 1: return "协议已识别 · 搜索功能待接入"
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

enum TVBoxSourceError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case responseTooLarge
    case invalidJSON
    case missingSites

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTP 或 HTTPS JSON 源地址。"
        case .httpStatus(let code): return "源服务器返回 HTTP \(code)。"
        case .responseTooLarge: return "源文件超过 10 MB，已停止解析。"
        case .invalidJSON: return "源文件不是有效的 TVBox JSON 配置。"
        case .missingSites: return "JSON 中没有找到 sites 站点列表。"
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
