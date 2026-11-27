import SwiftUI
import AVKit
import UIKit

struct HLSPlayerScreen: View {
    let url: URL
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var fillScreen = false

    private var directionMismatch: Bool {
        let deviceLandscape = deviceOrientation == .landscapeLeft || deviceOrientation == .landscapeRight
        let devicePortrait = deviceOrientation == .portrait || deviceOrientation == .portraitUpsideDown
        let screenLandscape = interfaceOrientation == .landscapeLeft || interfaceOrientation == .landscapeRight
        let screenPortrait = interfaceOrientation == .portrait || interfaceOrientation == .portraitUpsideDown
        return (deviceLandscape && screenPortrait) || (devicePortrait && screenLandscape)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if ["ts", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased()) {
                    VLCPlayerView(url: url)
                } else {
                    VideoPlayer(player: AVPlayer(url: url))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(fillScreen ? 1.16 : 1)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if directionMismatch {
                    Button(action: rotateToDevice) {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(13)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(18)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { fillScreen.toggle() } label: {
                    Image(systemName: fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(18)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateInterfaceOrientation()
        }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            deviceOrientation = UIDevice.current.orientation
            updateInterfaceOrientation()
        }
        .animation(.easeInOut(duration: 0.2), value: directionMismatch)
    }

    private func updateInterfaceOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        interfaceOrientation = scene.interfaceOrientation
    }

    private func rotateToDevice() {
        let target: UIInterfaceOrientationMask
        switch deviceOrientation {
        case .landscapeLeft: target = .landscapeLeft
        case .landscapeRight: target = .landscapeRight
        case .portrait, .portraitUpsideDown: target = .portrait
        default: return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        }
    }
}
