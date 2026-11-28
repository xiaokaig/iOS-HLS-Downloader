import SwiftUI
import AVKit
import UIKit

struct HLSPlayerScreen: View {
    let url: URL
    var headers: [String: String] = [:]
    var title: String? = nil
    var subtitle: String? = nil
    var preloadedAsset: AVURLAsset? = nil
    var tvboxPlayback: TVBoxPlayback? = nil
    var downloadQueue: DownloadQueueManager? = nil
    var resumePosition: Double = 0
    var onPlaybackProgress: ((TVBoxPlayback, Double, Double) -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    let onClose: () -> Void

    @State private var activePlayback: TVBoxPlayback?
    @State private var showingEpisodePicker = false
    @State private var downloadFeedback: String?
    @AppStorage("hlsStripMarkedAds") private var stripMarkedAds = true

    init(
        url: URL,
        headers: [String: String] = [:],
        title: String? = nil,
        subtitle: String? = nil,
        preloadedAsset: AVURLAsset? = nil,
        tvboxPlayback: TVBoxPlayback? = nil,
        downloadQueue: DownloadQueueManager? = nil,
        resumePosition: Double = 0,
        onPlaybackProgress: ((TVBoxPlayback, Double, Double) -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.headers = headers
        self.title = title
        self.subtitle = subtitle
        self.preloadedAsset = preloadedAsset
        self.tvboxPlayback = tvboxPlayback
        self.downloadQueue = downloadQueue
        self.resumePosition = resumePosition
        self.onPlaybackProgress = onPlaybackProgress
        self.onDownload = onDownload
        self.onClose = onClose
        _activePlayback = State(initialValue: tvboxPlayback)
        _resumePositionState = State(initialValue: resumePosition)
    }

    private var currentURL: URL { activePlayback?.url ?? url }
    private var currentTitle: String { activePlayback?.videoTitle ?? title ?? displayName }
    private var currentSubtitle: String {
        if let activePlayback { return "\(activePlayback.sourceName) · \(activePlayback.episodeName)" }
        return subtitle ?? (usesVLC ? "VLC 播放" : "正在播放")
    }
    private var canDownloadCurrent: Bool {
        if activePlayback != nil { return Self.isDownloadable(currentURL) }
        return onDownload != nil
    }

    @State private var fillScreen = false
    @State private var orientationMode: PlayerOrientationMode = .automatic
    @State private var playerErrorMessage: String?
    @State private var itemObservation: NSKeyValueObservation?
    @State private var timeControlObservation: NSKeyValueObservation?
    @State private var playerItemStatus: AVPlayerItem.Status = .unknown
    @State private var isBuffering = true
    @State private var vlcStatusMessage: String? = "正在连接视频源…"
    @State private var player: AVPlayer?
    @State private var periodicTimeObserver: Any?
    @State private var resumeAppliedURL = ""
    @State private var resumePositionState = 0.0
    @State private var lastKnownPlaybackPosition = 0.0
    @State private var lastKnownPlaybackDuration = 0.0
    @State private var lastPersistedPlaybackPosition = 0.0
    @State private var playbackRate = 1.0
    @State private var dragOffset: CGFloat = 0
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    private var usesVLC: Bool {
        ["ts", "mkv", "avi", "webm"].contains(currentURL.pathExtension.lowercased())
    }

    private var displayName: String {
        if let title, !title.isEmpty { return title }
        let name = currentURL.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "正在播放" : name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if usesVLC {
                    VLCPlayerView(url: currentURL, headers: headers, onStatusChange: { status in
                        vlcStatusMessage = status
                        if let status, status.hasPrefix("播放失败") { playerErrorMessage = status }
                    }, onProgressChange: { position, duration in
                        lastKnownPlaybackPosition = position
                        lastKnownPlaybackDuration = duration
                        if position - lastPersistedPlaybackPosition >= 10, let activePlayback {
                            lastPersistedPlaybackPosition = position
                            onPlaybackProgress?(activePlayback, position, duration)
                        }
                    })
                    .id(currentURL.absoluteString)
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
                    HStack(alignment: .bottom, spacing: 14) {
                        bottomActions
                        Spacer(minLength: 12)
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
        .overlay(alignment: .bottom) {
            if let downloadFeedback {
                Text(downloadFeedback)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 26)
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
            if !usesVLC { configureAVPlayer() }
            scheduleControlsHide()
        }
        .onChange(of: currentURL) { _ in
            playerErrorMessage = nil
            vlcStatusMessage = "正在连接视频源…"
            downloadFeedback = nil
            if usesVLC {
                lastKnownPlaybackPosition = 0
                lastKnownPlaybackDuration = 0
                lastPersistedPlaybackPosition = 0
                if let periodicTimeObserver, let player { player.removeTimeObserver(periodicTimeObserver) }
                periodicTimeObserver = nil
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                player = nil
                itemObservation = nil
                timeControlObservation = nil
            } else {
                configureAVPlayer()
            }
        }
        .sheet(isPresented: $showingEpisodePicker) {
            episodePicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            requestOrientation(.automatic)
            itemObservation = nil
            timeControlObservation = nil
            hideControlsTask?.cancel()
            savePlaybackProgress()
            if let periodicTimeObserver, let player { player.removeTimeObserver(periodicTimeObserver) }
            periodicTimeObserver = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(currentSubtitle)
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

    private var bottomActions: some View {
        HStack(spacing: 10) {
            if activePlayback != nil {
                Button { showingEpisodePicker = true } label: {
                    Label("选集", systemImage: "list.bullet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(.black.opacity(0.52), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                }
                .accessibilityLabel("选集和线路")
            }
            if canDownloadCurrent {
                Menu {
                    Toggle("跳过播放列表标记的广告", isOn: $stripMarkedAds)
                } label: {
                    Label("去广告", systemImage: "scissors")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 42)
                        .background(.black.opacity(0.52), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                }
                Button(action: downloadCurrent) {
                    Label("下载", systemImage: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(.black.opacity(0.52), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                }
                .accessibilityLabel("下载当前视频")
            }
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

    private var episodePicker: some View {
        NavigationStack {
            List {
                if let activePlayback {
                    ForEach(activePlayback.playSources) { source in
                        Section {
                            ForEach(source.episodes) { episode in
                                HStack(spacing: 10) {
                                    Button {
                                        selectEpisode(source: source, episode: episode)
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: source.id == activePlayback.selectedSourceID && episode.id == activePlayback.selectedEpisodeID ? "checkmark.circle.fill" : "play.circle")
                                                .foregroundStyle(source.id == activePlayback.selectedSourceID && episode.id == activePlayback.selectedEpisodeID ? .blue : .secondary)
                                            Text(episode.name)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 4)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if Self.isDownloadable(URL(string: episode.url) ?? URL(fileURLWithPath: "/")) {
                                        Button {
                                            enqueueTVBoxDownload(episode.url, fileName: "\(activePlayback.videoTitle)_\(episode.name)")
                                        } label: {
                                            Image(systemName: "arrow.down.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("下载\(episode.name)")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(source.name)
                                Spacer()
                                Button("下载本线路") {
                                    for episode in source.episodes { enqueueTVBoxDownload(episode.url) }
                                }
                                .font(.caption)
                                .disabled(!source.episodes.contains { Self.isDownloadable(URL(string: $0.url) ?? URL(fileURLWithPath: "/")) })
                            }
                        }
                    }
                }
            }
            .navigationTitle("选集与线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingEpisodePicker = false }
                }
            }
        }
    }

    private func selectEpisode(source: TVBoxPlaySource, episode: TVBoxEpisode) {
        guard let nextURL = URL(string: episode.url),
              ["http", "https"].contains(nextURL.scheme?.lowercased() ?? ""),
              let playback = activePlayback else { return }
        savePlaybackProgress()
        resumeAppliedURL = ""
        resumePositionState = 0
        lastKnownPlaybackPosition = 0
        lastKnownPlaybackDuration = 0
        lastPersistedPlaybackPosition = 0
        activePlayback = TVBoxPlayback(
            videoTitle: playback.videoTitle,
            sourceName: source.name,
            episodeName: episode.name,
            url: nextURL,
            playSources: playback.playSources,
            selectedSourceID: source.id,
            selectedEpisodeID: episode.id
        )
        showingEpisodePicker = false
        scheduleControlsHide()
    }

    private func downloadCurrent() {
        if let activePlayback {
            enqueueTVBoxDownload(activePlayback.url.absoluteString, fileName: "\(activePlayback.videoTitle)_\(activePlayback.episodeName)")
        } else {
            onDownload?()
            downloadFeedback = "已加入下载队列"
        }
    }

    private func enqueueTVBoxDownload(_ address: String, fileName: String? = nil) {
        guard let queue = downloadQueue,
              let target = URL(string: address),
              Self.isDownloadable(target) else { return }
        if target.pathExtension.lowercased() == "m3u8" {
            queue.enqueueHLS(target, fileName: fileName, stripMarkedAds: stripMarkedAds)
        } else {
            queue.enqueueDirect(target)
        }
        downloadFeedback = "已加入下载队列"
    }

    private static func isDownloadable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ["mp4", "m4v", "mov", "ts", "mkv", "avi", "webm", "flv"].contains(ext)
    }

    @MainActor
    private func configureAVPlayer() {
        guard !usesVLC else { return }
        itemObservation = nil
        timeControlObservation = nil
        player?.pause()
        playerItemStatus = .unknown
        isBuffering = true
        let asset: AVURLAsset
        if let activePlayback {
            asset = TVBoxPlaybackPreloader.shared.asset(for: activePlayback.url)
        } else if currentURL == url, let preloadedAsset {
            asset = preloadedAsset
        } else {
            asset = AVURLAsset(url: currentURL, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            DispatchQueue.main.async {
                playerItemStatus = observed.status
                if observed.status == .failed {
                    playerErrorMessage = observed.error?.localizedDescription ?? "视频资源加载失败，请检查链接、Cookie 或 Referer。"
                } else if observed.status == .readyToPlay,
                          resumePositionState > 0,
                          resumeAppliedURL != currentURL.absoluteString {
                    resumeAppliedURL = currentURL.absoluteString
                    player?.seek(to: CMTime(seconds: resumePositionState, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        if let player {
            if let periodicTimeObserver { player.removeTimeObserver(periodicTimeObserver); self.periodicTimeObserver = nil }
            player.replaceCurrentItem(with: item)
            timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
                DispatchQueue.main.async {
                    isBuffering = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            player.play()
        } else {
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
        if let player {
            periodicTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 10, preferredTimescale: 600),
                queue: .main
            ) { time in
                guard let activePlayback,
                      time.seconds.isFinite, time.seconds >= 0 else { return }
                let duration = player.currentItem?.duration.seconds ?? 0
                lastKnownPlaybackPosition = time.seconds
                lastKnownPlaybackDuration = duration.isFinite ? duration : 0
                if time.seconds - lastPersistedPlaybackPosition >= 10 {
                    lastPersistedPlaybackPosition = time.seconds
                    onPlaybackProgress?(activePlayback, time.seconds, lastKnownPlaybackDuration)
                }
            }
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

    private func savePlaybackProgress() {
        guard let activePlayback else { return }
        let playerPosition = player?.currentTime().seconds ?? lastKnownPlaybackPosition
        let position = playerPosition.isFinite && playerPosition >= 0 ? playerPosition : lastKnownPlaybackPosition
        let playerDuration = player?.currentItem?.duration.seconds ?? lastKnownPlaybackDuration
        let duration = playerDuration.isFinite ? playerDuration : lastKnownPlaybackDuration
        onPlaybackProgress?(activePlayback, position, duration)
    }

    private func closePlayer() {
        savePlaybackProgress()
        requestOrientation(.automatic)
        hideControlsTask?.cancel()
        player?.pause()
        onClose()
    }
}

private enum PlayerOrientationMode {
    case portrait, landscape, automatic
}
