import SwiftUI
import VLCKit

struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        context.coordinator.player.drawable = view
        context.coordinator.player.media = VLCMedia(url: url)
        context.coordinator.player.play()
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.player.stop()
        context.coordinator.url = url
        context.coordinator.player.media = VLCMedia(url: url)
        context.coordinator.player.play()
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.player.stop()
        coordinator.player.drawable = nil
    }
    final class Coordinator {
        let player = VLCMediaPlayer()
        var url: URL
        init(url: URL) { self.url = url }
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
