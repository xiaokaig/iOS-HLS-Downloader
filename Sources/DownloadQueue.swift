import Foundation
import Combine
import UserNotifications
import UIKit

enum DownloadQueueState: String {
    case queued = "排队中"
    case downloading = "下载中"
    case paused = "已暂停"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
}

enum DownloadQueueKind {
    case hls(URL, [HTTPCookie])
    case direct(URL, [HTTPCookie], URL?)

    var sourceURL: URL {
        switch self {
        case .hls(let url, _): return url
        case .direct(let url, _, _): return url
        }
    }

    var title: String {
        let name = sourceURL.lastPathComponent
        return name.isEmpty ? (sourceURL.host ?? "视频下载") : name
    }
}

@MainActor
final class DownloadQueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let kind: DownloadQueueKind
    let hlsManager: HLSDownloadManager?
    let directManager: DirectVideoDownloadManager?

    @Published var state: DownloadQueueState = .queued
    @Published var progress = 0.0
    @Published var status = "等待开始"
    @Published var outputURL: URL?
    @Published var errorMessage: String?
    @Published var conversionWarning: String?

    var runner: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(kind: DownloadQueueKind) {
        self.kind = kind
        switch kind {
        case .hls(_, _):
            let manager = HLSDownloadManager()
            hlsManager = manager
            directManager = nil
            manager.$progress.receive(on: DispatchQueue.main).sink { [weak self] in
                guard self?.state == .downloading else { return }
                self?.progress = $0
            }.store(in: &cancellables)
            manager.$status.receive(on: DispatchQueue.main).sink { [weak self] in
                guard self?.state == .downloading else { return }
                self?.status = $0
            }.store(in: &cancellables)
            manager.$conversionWarning.receive(on: DispatchQueue.main).sink { [weak self] in
                self?.conversionWarning = $0
            }.store(in: &cancellables)
        case .direct(_, _, _):
            let manager = DirectVideoDownloadManager()
            hlsManager = nil
            directManager = manager
            manager.$progress.receive(on: DispatchQueue.main).sink { [weak self] in
                guard self?.state == .downloading else { return }
                self?.progress = $0
            }.store(in: &cancellables)
            manager.$status.receive(on: DispatchQueue.main).sink { [weak self] in
                guard self?.state == .downloading else { return }
                self?.status = $0
            }.store(in: &cancellables)
        }
    }

    var sourceURL: URL { kind.sourceURL }
    var title: String { kind.title }
}

@MainActor
final class DownloadQueueManager: ObservableObject {
    @Published private(set) var items: [DownloadQueueItem] = []
    private var activeIDs = Set<UUID>()
    private let maximumConcurrent = 3
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundExpired = false
    var onCompleted: ((URL, URL?) -> Void)?

    var activeCount: Int { activeIDs.count }
    var queuedCount: Int { items.filter { $0.state == .queued }.count }

    @discardableResult
    func enqueueHLS(_ url: URL, cookies: [HTTPCookie] = []) -> DownloadQueueItem {
        if let existing = items.first(where: { $0.sourceURL == url && [.queued, .downloading, .paused].contains($0.state) }) {
            return existing
        }
        let item = DownloadQueueItem(kind: .hls(url, cookies))
        items.insert(item, at: 0)
        pump()
        return item
    }

    @discardableResult
    func enqueueDirect(_ url: URL, cookies: [HTTPCookie] = [], referrer: URL? = nil) -> DownloadQueueItem {
        if let existing = items.first(where: { $0.sourceURL == url && [.queued, .downloading, .paused].contains($0.state) }) {
            return existing
        }
        let item = DownloadQueueItem(kind: .direct(url, cookies, referrer))
        items.insert(item, at: 0)
        pump()
        return item
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationDidBecomeActive() {
        backgroundExpired = false
        for item in items where item.state == .paused && item.status == "系统后台时间到期，已暂停" {
            item.state = .queued
        }
        pump()
    }

    func pause(_ item: DownloadQueueItem) {
        guard item.state == .downloading else { return }
        item.state = .paused
        item.status = "已暂停"
        if let direct = item.directManager {
            direct.pause()
            activeIDs.remove(item.id)
            finishBackgroundTaskIfIdle()
            pump()
        } else {
            item.runner?.cancel()
        }
    }

    func resume(_ item: DownloadQueueItem) {
        guard item.state == .paused else { return }
        item.state = .queued
        item.status = "等待继续"
        pump()
    }

    func cancel(_ item: DownloadQueueItem) {
        guard item.state == .downloading || item.state == .queued || item.state == .paused else { return }
        let wasDownloading = item.state == .downloading
        item.state = .cancelled
        item.runner?.cancel()
        item.directManager?.cancel()
        if item.directManager != nil || !wasDownloading {
            activeIDs.remove(item.id)
        }
        item.status = "已取消"
        finishBackgroundTaskIfIdle()
        pump()
    }

    func retry(_ item: DownloadQueueItem) {
        guard item.state == .failed || item.state == .cancelled else { return }
        item.errorMessage = nil
        item.progress = 0
        item.state = .queued
        item.status = "等待重试"
        pump()
    }

    func remove(_ item: DownloadQueueItem) {
        if item.state == .downloading || item.state == .queued || item.state == .paused {
            cancel(item)
        }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }
    }

    private func pump() {
        guard !backgroundExpired else { return }
        while activeIDs.count < maximumConcurrent,
              let next = items.first(where: { $0.state == .queued && !activeIDs.contains($0.id) }) {
            start(next)
        }
        objectWillChange.send()
    }

    private func start(_ item: DownloadQueueItem) {
        beginBackgroundTaskIfNeeded()
        guard activeIDs.insert(item.id).inserted else { return }
        item.state = .downloading
        item.errorMessage = nil

        if let hls = item.hlsManager, case .hls(let url, let cookies) = item.kind {
            item.runner = Task { [weak self, weak item] in
                guard let item else { return }
                do {
                    let output = try await hls.start(url: url, cookies: cookies)
                    self?.finish(item, output: output)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        self?.activeIDs.remove(item.id)
                        if item.state == .paused && self?.backgroundExpired != true { item.status = "已暂停" }
                        self?.finishBackgroundTaskIfIdle()
                        self?.pump()
                    } else {
                        self?.finishWithError(item, error: error)
                    }
                }
            }
        } else if let direct = item.directManager, case .direct(let url, let cookies, let referrer) = item.kind {
            direct.onCompletion = { [weak self, weak item] result in
                Task { @MainActor in
                    guard let self, let item else { return }
                    switch result {
                    case .success(let output): self.finish(item, output: output)
                    case .failure(let error): self.finishWithError(item, error: error)
                    }
                }
            }
            if direct.isPaused {
                direct.resume()
            } else {
                direct.start(url: url, cookies: cookies, referrer: referrer)
            }
        }
    }

    private func finish(_ item: DownloadQueueItem, output: URL) {
        activeIDs.remove(item.id)
        item.outputURL = output
        item.progress = 1
        item.state = .completed
        item.status = "下载完成"
        onCompleted?(output, item.sourceURL)
        notifyCompletion(item.title)
        finishBackgroundTaskIfIdle()
        pump()
    }

    private func finishWithError(_ item: DownloadQueueItem, error: Error) {
        activeIDs.remove(item.id)
        if item.state != .paused && item.state != .cancelled {
            item.state = .failed
            item.errorMessage = error.localizedDescription
            item.status = "下载失败：\(error.localizedDescription)"
        }
        finishBackgroundTaskIfIdle()
        pump()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoDownloads") { [weak self] in
            Task { @MainActor in self?.expireBackgroundExecution() }
        }
    }

    private func finishBackgroundTaskIfIdle() {
        guard activeIDs.isEmpty, backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func expireBackgroundExecution() {
        backgroundExpired = true
        for item in items where item.state == .downloading {
            item.state = .paused
            item.status = "系统后台时间到期，已暂停"
            item.directManager?.pause()
            item.runner?.cancel()
        }
        activeIDs.removeAll()
        finishBackgroundTaskIfIdle()
        objectWillChange.send()
    }

    private func notifyCompletion(_ title: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = title
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

struct DownloadQueueRow: View {
    @ObservedObject var item: DownloadQueueItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.state == .completed ? "checkmark.circle.fill" : (item.state == .failed ? "exclamationmark.circle.fill" : "arrow.down.circle"))
                    .foregroundStyle(item.state == .completed ? .green : (item.state == .failed ? .red : .blue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(item.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text(item.state.rawValue).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if item.state == .downloading || item.state == .paused {
                ProgressView(value: item.progress)
                Text(item.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let warning = item.conversionWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                if item.state == .downloading {
                    Button(action: onPause) { Label("暂停", systemImage: "pause.fill") }
                    Button(action: onCancel) { Label("取消", systemImage: "xmark") }.foregroundStyle(.red)
                } else if item.state == .paused {
                    Button(action: onResume) { Label("继续", systemImage: "play.fill") }
                    Button(action: onCancel) { Label("取消", systemImage: "xmark") }.foregroundStyle(.red)
                } else if item.state == .failed || item.state == .cancelled {
                    Button(action: onRetry) { Label("重试", systemImage: "arrow.clockwise") }
                    Button(action: onRemove) { Label("移除", systemImage: "trash") }.foregroundStyle(.red)
                } else if item.state == .completed {
                    if let output = item.outputURL {
                        ShareLink(item: output) { Label("分享", systemImage: "square.and.arrow.up") }
                    }
                    Button(action: onRemove) { Label("移除记录", systemImage: "trash") }.foregroundStyle(.red)
                } else {
                    Button(action: onCancel) { Label("取消排队", systemImage: "xmark") }.foregroundStyle(.red)
                }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}
