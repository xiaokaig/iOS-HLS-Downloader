import SwiftUI
import AVKit
import UIKit

struct HLSPlayerScreen: View {
    let url: URL
    let onClose: () -> Void

    @State private var fillScreen = false
    @State private var player: AVPlayer?
    @State private var playbackRate = 1.0
    @State private var dragOffset: CGFloat = 0

    private var usesVLC: Bool {
        ["ts", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased())
    }

    private var displayName: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "正在播放" : name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if usesVLC {
                    VLCPlayerView(url: url)
                } else {
                    VideoPlayer(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(fillScreen ? 1.12 : 1)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.black.opacity(0.72), .black.opacity(0.28), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                HStack(spacing: 12) {
                    Button(action: closePlayer) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("返回浏览器")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(usesVLC ? "本地视频 · VLC" : "本地视频")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer(minLength: 8)

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
                            Text("\(playbackRate, specifier: "%.2g")×")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13)
                                .frame(height: 38)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .accessibilityLabel("播放速度")
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { fillScreen.toggle() }
                    } label: {
                        Image(systemName: fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(fillScreen ? "还原画面" : "填充画面")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
        }
        .offset(y: dragOffset)
        .statusBarHidden(true)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
                    dragOffset = min(value.translation.height, 240)
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
                let newPlayer = AVPlayer(url: url)
                newPlayer.allowsExternalPlayback = true
                player = newPlayer
                newPlayer.play()
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
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
    }

    private func closePlayer() {
        player?.pause()
        onClose()
    }
}
