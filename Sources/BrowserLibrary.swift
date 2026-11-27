import Foundation
import Combine

struct BrowserBookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var createdAt = Date()
}

struct BrowsingHistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var visitedAt = Date()
}

struct DownloadHistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String
    var fileURL: String
    var sourceURL: String?
    var completedAt = Date()
}

@MainActor
final class BrowserLibraryStore: ObservableObject {
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    @Published private(set) var browsingHistory: [BrowsingHistoryEntry] = []
    @Published private(set) var history: [DownloadHistoryEntry] = []

    private let bookmarksKey = "browserBookmarks.v1"
    private let browsingHistoryKey = "browsingHistory.v1"
    private let historyKey = "downloadHistory.v1"

    init() {
        bookmarks = Self.load([BrowserBookmark].self, key: bookmarksKey, defaultValue: [])
        browsingHistory = Self.load([BrowsingHistoryEntry].self, key: browsingHistoryKey, defaultValue: [])
        history = Self.load([DownloadHistoryEntry].self, key: historyKey, defaultValue: [])
    }

    func recordVisit(url: URL, title: String) {
        let value = url.absoluteString
        if let first = browsingHistory.first, first.url == value,
           Date().timeIntervalSince(first.visitedAt) < 3 {
            return
        }
        browsingHistory.insert(BrowsingHistoryEntry(title: title, url: value), at: 0)
        if browsingHistory.count > 500 { browsingHistory = Array(browsingHistory.prefix(500)) }
        persist(browsingHistory, key: browsingHistoryKey)
    }

    func removeBrowsingVisit(_ id: UUID) {
        browsingHistory.removeAll { $0.id == id }
        persist(browsingHistory, key: browsingHistoryKey)
    }

    func clearBrowsingHistory() {
        browsingHistory.removeAll()
        persist(browsingHistory, key: browsingHistoryKey)
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url.absoluteString }
    }

    func addBookmark(url: URL, title: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks[index].title = title
        } else {
            bookmarks.insert(BrowserBookmark(title: title, url: url.absoluteString), at: 0)
        }
        persist(bookmarks, key: bookmarksKey)
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist(bookmarks, key: bookmarksKey)
    }

    func recordDownload(fileURL: URL, sourceURL: URL?) {
        let path = fileURL.absoluteString
        history.removeAll { $0.fileURL == path }
        history.insert(
            DownloadHistoryEntry(
                fileName: fileURL.lastPathComponent,
                fileURL: path,
                sourceURL: sourceURL?.absoluteString
            ),
            at: 0
        )
        if history.count > 200 { history = Array(history.prefix(200)) }
        persist(history, key: historyKey)
    }

    func removeHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        persist(history, key: historyKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaultValue: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(type, from: data) else { return defaultValue }
        return value
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

final class DirectVideoDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "等待下载"
    @Published private(set) var outputURL: URL?
    @Published private(set) var isDownloading = false

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func start(url: URL, cookies: [HTTPCookie], referrer: URL?) {
        guard !isDownloading else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        if let host = url.host?.lowercased() {
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let domainMatches = host == domain || host.hasSuffix("." + domain)
                let pathMatches = url.path.hasPrefix(cookie.path)
                let secureMatches = !cookie.isSecure || url.scheme?.lowercased() == "https"
                return domainMatches && pathMatches && secureMatches
            }
            for (name, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }

        progress = 0
        outputURL = nil
        status = "正在下载普通视频…"
        isDownloading = true
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = newSession
        let newTask = newSession.downloadTask(with: request)
        task = newTask
        newTask.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            if totalBytesExpectedToWrite > 0 {
                self.progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                self.status = "正在下载普通视频…"
            } else {
                self.status = "正在下载（服务器未提供总大小）…"
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            finishWithError("服务器返回 HTTP \(code)")
            return
        }

        let rawName = response.suggestedFilename
            ?? downloadTask.originalRequest?.url?.lastPathComponent
            ?? "video"
        let mime = (response.mimeType ?? "").lowercased()
        let inferredExtension: String
        switch mime {
        case "video/webm": inferredExtension = "webm"
        case "video/quicktime": inferredExtension = "mov"
        case "video/x-m4v": inferredExtension = "m4v"
        default: inferredExtension = "mp4"
        }
        let suggested = URL(fileURLWithPath: rawName).pathExtension.isEmpty
            ? rawName + "." + inferredExtension : rawName
        let safeName = Self.safeFilename(suggested)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destination = documents.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            destination = documents.appendingPathComponent("\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.outputURL = destination
                self.progress = 1
                self.status = "普通视频下载完成"
                self.isDownloading = false
                self.task = nil
                self.session?.finishTasksAndInvalidate()
                self.session = nil
            }
        } catch {
            finishWithError("保存文件失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finishWithError(error.localizedDescription) }
    }

    private func finishWithError(_ message: String) {
        DispatchQueue.main.async {
            self.status = "下载失败：\(message)"
            self.isDownloading = false
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "video.mp4" : cleaned
    }
}
