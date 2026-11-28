import SwiftUI
import AVFoundation
import VLCKit

struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var onStatusChange: (String?) -> Void = { _ in }
    var onProgressChange: (Double, Double) -> Void = { _, _ in }
    func makeCoordinator() -> Coordinator { Coordinator(url: url, headers: headers, onStatusChange: onStatusChange, onProgressChange: onProgressChange) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
        try? audioSession.setActive(true)
        context.coordinator.player.delegate = context.coordinator
        context.coordinator.player.drawable = view
        context.coordinator.player.media = context.coordinator.makeMedia(url: url)
        context.coordinator.player.play()
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.player.stop()
        context.coordinator.url = url
        context.coordinator.player.media = context.coordinator.makeMedia(url: url)
        context.coordinator.player.play()
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.player.stop()
        coordinator.player.drawable = nil
    }
    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        let player = VLCMediaPlayer()
        var url: URL
        var headers: [String: String]
        let onStatusChange: (String?) -> Void
        let onProgressChange: (Double, Double) -> Void
        private var lastReportedSecond = -10.0
        init(url: URL, headers: [String: String], onStatusChange: @escaping (String?) -> Void, onProgressChange: @escaping (Double, Double) -> Void) {
            self.url = url
            self.headers = headers
            self.onStatusChange = onStatusChange
            self.onProgressChange = onProgressChange
        }
        func mediaPlayerStateChanged(_ notification: Notification!) {
            let currentState = player.state
            let message: String?
            switch currentState {
            case .opening: message = "正在连接视频源…"
            case .buffering: message = "正在缓冲视频…"
            case .playing: message = nil
            case .error: message = "播放失败：VLC 无法读取该视频地址。"
            case .ended: message = nil
            default: message = "正在加载视频源…"
            }
            DispatchQueue.main.async { self.onStatusChange(message) }
        }
        func mediaPlayerTimeChanged(_ notification: Notification!) {
            let position = Double(player.time.intValue) / 1000
            let duration = Double(player.media.length.intValue) / 1000
            guard position.isFinite, position >= 0, position - lastReportedSecond >= 10 else { return }
            lastReportedSecond = position
            DispatchQueue.main.async { self.onProgressChange(position, duration.isFinite ? duration : 0) }
        }
        func makeMedia(url: URL) -> VLCMedia {
            let media = VLCMedia(url: url)
            var options: [String: Any] = [:]
            if let value = headers["Referer"] { options[":http-referrer"] = value }
            if let value = headers["Cookie"] { options[":http-cookie"] = value }
            if !options.isEmpty { media.addOptions(options) }
            return media
        }
    }
}

@MainActor
final class VLCTSRemuxer: NSObject, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    func remux(source: URL, destination: URL) async throws -> URL {
        self.destination = destination
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            player.delegate = self
            let media = VLCMedia(url: source)
            media.addOptions(["sout": "#standard{access=file,mux=mp4,dst=\(destination.path)}", "sout-keep": NSNull()])
            player.media = media
            player.play()
        }
    }

    func mediaPlayerStateChanged(_ notification: Notification!) {
        switch player.state {
        case .ended:
            player.stop()
            guard let destination,
                  let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber,
                  size.int64Value > 0 else {
                finish(.failure(NSError(domain: "VLCRemux", code: 2, userInfo: [NSLocalizedDescriptionKey: "VLC 未生成有效 MP4 文件"])))
                return
            }
            finish(.success(destination))
        case .error:
            player.stop()
            finish(.failure(NSError(domain: "VLCRemux", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前 TS 音视频流无法无损封装为 MP4"])))
        default: break
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        player.delegate = nil
        continuation.resume(with: result)
    }
    deinit { player.stop() }
}
