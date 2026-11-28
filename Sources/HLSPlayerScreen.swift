import SwiftUI
import AVKit
import UIKit

struct HLSPlayerScreen: View {
    let url: URL
    var headers: [String: String] = [:]
    var title: String? = nil
    var subtitle: String? = nil
    var preloadedAsset: AVURLAsset? = nil
    let onClose: () -> Void

    @State private var fillScreen = false
    @State private var orientationMode: PlayerOrientationMode = .automatic
    @State private var playerErrorMessage: String?
    @State private var itemObservation: NSKeyValueObservation?
    @State private var timeControlObservation: NSKeyValueObservation?
    @State private var playerItemStatus: AVPlayerItem.Status = .unknown
    @State private var isBuffering = true
    @State private var vlcStatusMessage: String? = "正在连接视频源…"
    @State private var player: AVPlayer?
    @State private var playbackRate = 1.0
    @State private var dragOffset: CGFloat = 0
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    private var usesVLC: Bool {
        ["ts", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased())
    }

    private var displayName: String {
        if let title, !title.isEmpty { return title }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "正在播放" : name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if usesVLC {
                    VLCPlayerView(url: url, headers: headers, onStatusChange: { status in
                        vlcStatusMessage = status
                        if let status, status.hasPrefix("播放失败") { playerErrorMessage = status }
                    })
                } else {
                    VideoPlayer(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(fillScreen ? 1.12 : 1)
            .clipped()
            .ignoresSafeArea()

            if usesVLC, let vlcStatusMessage, playerErrorMessage == nil {
                VStack(spacing: 12) {
                    ProgressView().tint(.white).scaleEffect(1.2)
                    Text(vlcStatusMessage).font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                .padding(18)
                .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
            } else if !usesVLC, playerErrorMessage == nil && (playerItemStatus != .readyToPlay || isBuffering) {
                VStack(spacing: 12) {
                    ProgressView().tint(.white).scaleEffect(1.2)
                    Text(playerItemStatus == .readyToPlay ? "正在缓冲视频…" : "正在加载视频源…")
                        .font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                .padding(18)
                .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
            }

            if let playerErrorMessage {
                VStack {
                    Spacer()
                    Text(playerErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                }
                .padding(.horizontal, 24)
            }

            if controlsVisible {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 20)
                    HStack {
                        Spacer()
                        sideControls
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .transition(.opacity)
            }
        }
        .offset(y: dragOffset)
        .statusBarHidden(false)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible.toggle()
                }
                if controlsVisible { scheduleControlsHide() }
                else { hideControlsTask?.cancel() }
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
                    dragOffset = min(value.translation.height, 260)
                }
                .onEnded { value in
                    let isDownward = value.translation.height > 0 &&
                        abs(value.translation.height) > abs(value.translation.width) * 1.2
                    if isDownward && (value.translation.height > 105 || value.predictedEndTranslation.height > 165) {
                        closePlayer()
                    } else {
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            if !usesVLC {
                let asset = preloadedAsset ?? AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
                let item = AVPlayerItem(asset: asset)
                itemObservation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                    DispatchQueue.main.async {
                        playerItemStatus = observed.status
                        if observed.status == .failed {
                            playerErrorMessage = observed.error?.localizedDescription ?? "视频资源加载失败，请检查链接、Cookie 或 Referer。"
                        }
                    }
                }
                let newPlayer = AVPlayer(playerItem: item)
                timeControlObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
                    DispatchQueue.main.async {
                        isBuffering = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    }
                }
                newPlayer.allowsExternalPlayback = true
                player = newPlayer
                newPlayer.play()
            }
            scheduleControlsHide()
        }
        .onDisappear {
            requestOrientation(.automatic)
            itemObservation = nil
            timeControlObservation = nil
            hideControlsTask?.cancel()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle ?? (usesVLC ? "VLC 播放" : "正在播放"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 12)
            Button(action: closePlayer) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.42), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            }
            .accessibilityLabel("关闭播放器")
        }
        .padding(.top, 4)
        .background(alignment: .top) {
            LinearGradient(
                colors: [.black.opacity(0.62), .black.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .padding(.horizontal, -22)
            .padding(.top, -12)
            .allowsHitTesting(false)
        }
    }

    private var sideControls: some View {
        VStack(spacing: 12) {
            Menu {
                Button { setOrientation(.portrait) } label: {
                    Label("竖屏", systemImage: orientationMode == .portrait ? "checkmark" : "iphone")
                }
                Button { setOrientation(.landscape) } label: {
                    Label("横屏", systemImage: orientationMode == .landscape ? "checkmark" : "iphone.landscape")
                }
                Button { setOrientation(.automatic) } label: {
                    Label("自动旋转", systemImage: orientationMode == .automatic ? "checkmark" : "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: orientationMode == .landscape ? "iphone.landscape" : "iphone")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.46), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            }
            .accessibilityLabel("屏幕方向")

            if !usesVLC {
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            setPlaybackRate(rate)
                        } label: {
                            if playbackRate == rate {
                                Label("\(rate, specifier: "%.2g")×", systemImage: "checkmark")
                            } else {
                                Text("\(rate, specifier: "%.2g")×")
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 17, weight: .medium))
                        Text("\(playbackRate, specifier: "%.2g")×")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.46), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                }
                .accessibilityLabel("播放速度")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { fillScreen.toggle() }
                scheduleControlsHide()
            } label: {
                Image(systemName: fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.46), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            }
            .accessibilityLabel(fillScreen ? "还原画面" : "填充画面")
        }
    }

    private func setOrientation(_ mode: PlayerOrientationMode) {
        orientationMode = mode
        requestOrientation(mode)
        scheduleControlsHide()
    }

    private func requestOrientation(_ mode: PlayerOrientationMode) {
        let mask: UIInterfaceOrientationMask
        switch mode {
        case .portrait: mask = .portrait
        case .landscape: mask = [.landscapeLeft, .landscapeRight]
        case .automatic: mask = .allButUpsideDown
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                AppDiagnostics.shared.log("PLAYER", "方向切换失败：\(error.localizedDescription)")
            }
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    controlsVisible = false
                }
            }
        }
    }

    private func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.rate = Float(rate)
        } else {
            player.defaultRate = Float(rate)
        }
        scheduleControlsHide()
    }

    private func closePlayer() {
        requestOrientation(.automatic)
        hideControlsTask?.cancel()
        player?.pause()
        onClose()
    }
}

private enum PlayerOrientationMode {
    case portrait, landscape, automatic
}
