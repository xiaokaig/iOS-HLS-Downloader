import Foundation
import Combine
import Security


struct AListDirectory: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

enum AListUploadError: LocalizedError {
    case invalidServer
    case invalidCredentials
    case invalidResponse
    case server(String)
    case fileUnavailable
    case uploadInProgress

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "AList 地址无效，请填写完整的 HTTP 或 HTTPS 地址。"
        case .invalidCredentials: return "AList 登录失败，请检查账号、密码或二步验证码。"
        case .invalidResponse: return "AList 返回了无法识别的响应。"
        case .server(let message): return message
        case .fileUnavailable: return "本地文件不存在或无法读取。"
        case .uploadInProgress: return "当前已有文件正在上传。"
        }
    }
}

enum AListCredentialStore {
    private static let service = "com.xiaokaig.hlsdownloader.alist"
    private static let account = "upload-password"

    static func save(password: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AListUploadManager: NSObject, ObservableObject, URLSessionUploadDelegate {
    @Published private(set) var isUploading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var currentFilePath: String?
    @Published private(set) var status = "尚未上传"

    private var session: URLSession?
    private var uploadTask: URLSessionUploadTask?
    private var continuation: CheckedContinuation<Void, Error>?

    func testConnection(
        serverAddress: String,
        username: String,
        password: String,
        otpCode: String
    ) async throws {
        _ = try await login(
            serverAddress: serverAddress,
            username: username,
            password: password,
            otpCode: otpCode
        )
    }

    func listDirectories(
        serverAddress: String,
        username: String,
        password: String,
        otpCode: String,
        directory: String
    ) async throws -> [AListDirectory] {
        let token = try await login(
            serverAddress: serverAddress,
            username: username,
            password: password,
            otpCode: otpCode
        )
        let endpoint = try makeEndpoint(serverAddress: serverAddress, path: "api/fs/list")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": directory.isEmpty ? "/" : directory,
            "password": "",
            "page": 1,
            "per_page": 200,
            "refresh": false
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AListUploadError.invalidResponse
        }
        let code = object["code"] as? Int ?? 0
        guard code == 200 else {
            throw AListUploadError.server(object["message"] as? String ?? "读取 AList 目录失败")
        }
        let payload = object["data"] as? [String: Any]
        let entries = payload?["content"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard (entry["is_dir"] as? Bool) == true,
                  let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return AListDirectory(name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func upload(
        fileURL: URL,
        serverAddress: String,
        username: String,
        password: String,
        otpCode: String,
        targetDirectory: String
    ) async throws {
        guard !isUploading else { throw AListUploadError.uploadInProgress }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            throw AListUploadError.fileUnavailable
        }

        let token = try await login(
            serverAddress: serverAddress,
            username: username,
            password: password,
            otpCode: otpCode
        )
        let endpoint = try makeEndpoint(serverAddress: serverAddress, path: "api/fs/put")
        let directory = targetDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = "/" + (directory.isEmpty ? "" : directory + "/") + fileURL.lastPathComponent
        guard let encodedPath = Self.encodeFilePath(fullPath) else {
            throw AListUploadError.invalidServer
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60 * 60
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(encodedPath, forHTTPHeaderField: "File-Path")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        progress = 0
        status = "正在上传…"
        currentFilePath = fileURL.path
        isUploading = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60 * 60
            configuration.timeoutIntervalForResource = 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            self.session = session
            let task = session.uploadTask(with: request, fromFile: fileURL) { [weak self] data, response, error in
                Task { @MainActor in
                    self?.finishUpload(data: data, response: response, error: error)
                }
            }
            self.uploadTask = task
            task.resume()
        }
    }

    func cancel() {
        uploadTask?.cancel()
        status = "正在取消上传…"
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let sent = ByteCountFormatter.string(fromByteCount: totalBytesSent, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToSend, countStyle: .file)
        Task { @MainActor in
            self.progress = fraction
            self.status = "上传中 · \(sent) / \(total)"
        }
    }

    private func finishUpload(data: Data?, response: URLResponse?, error: Error?) {
        defer {
            uploadTask = nil
            session?.finishTasksAndInvalidate()
            session = nil
            isUploading = false
            currentFilePath = nil
        }

        if let error {
            status = "上传失败：\(error.localizedDescription)"
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        guard let http = response as? HTTPURLResponse else {
            let error = AListUploadError.invalidResponse
            status = "上传失败：\(error.localizedDescription)"
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        guard (200..<300).contains(http.statusCode),
              let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = "HTTP \(http.statusCode)"
            let error = AListUploadError.server(message)
            status = "上传失败：\(message)"
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        let code = object["code"] as? Int ?? http.statusCode
        guard code == 200 else {
            let message = object["message"] as? String ?? "AList 错误码 \(code)"
            let error = AListUploadError.server(message)
            status = "上传失败：\(message)"
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        progress = 1
        status = "上传完成"
        continuation?.resume()
        continuation = nil
    }

    private func login(
        serverAddress: String,
        username: String,
        password: String,
        otpCode: String
    ) async throws -> String {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw AListUploadError.invalidCredentials
        }
        let endpoint = try makeEndpoint(serverAddress: serverAddress, path: "api/auth/login")
        var body: [String: String] = ["username": username, "password": password]
        let otp = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !otp.isEmpty { body["otp_code"] = otp }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AListUploadError.invalidCredentials
        }
        let code = object["code"] as? Int ?? http.statusCode
        guard code == 200,
              let payload = object["data"] as? [String: Any],
              let token = payload["token"] as? String,
              !token.isEmpty else {
            throw AListUploadError.server(object["message"] as? String ?? "AList 登录失败")
        }
        return token
    }

    private func makeEndpoint(serverAddress: String, path: String) throws -> URL {
        let raw = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let base = URL(string: normalized),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AListUploadError.invalidServer
        }
        let prefix = components.path == "/" ? "" : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (prefix.isEmpty ? "" : prefix + "/") + path
        guard let url = components.url else { throw AListUploadError.invalidServer }
        return url
    }

    private static func encodeFilePath(_ path: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
        }
        return parts.joined(separator: "/")
    }
}
