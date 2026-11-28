import SwiftUI

struct TVBoxPlaybackHistoryEntry: Codable, Identifiable {
    let id: String
    let playback: TVBoxPlayback
    var position: Double
    var duration: Double
    var lastPlayed: Date
}

@MainActor
final class TVBoxPlaybackHistory: ObservableObject {
    static let shared = TVBoxPlaybackHistory()
    @Published private(set) var entries: [TVBoxPlaybackHistoryEntry] = []
    private let storageKey = "tvboxPlaybackHistory"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([TVBoxPlaybackHistoryEntry].self, from: data) else { return }
        entries = saved.sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func record(_ playback: TVBoxPlayback, position: Double, duration: Double) {
        let key = Self.stableID(for: playback)
        var updated = entries.filter { $0.id != key }
        updated.insert(TVBoxPlaybackHistoryEntry(
            id: key,
            playback: playback,
            position: max(0, position),
            duration: duration.isFinite ? max(0, duration) : 0,
            lastPlayed: Date()
        ), at: 0)
        entries = Array(updated.prefix(100))
        persist()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func stableID(for playback: TVBoxPlayback) -> String {
        let firstEpisode = playback.playSources.first?.episodes.first?.url ?? playback.url.absoluteString
        return playback.videoTitle + "|" + firstEpisode
    }
}

struct TVBoxPlaybackHistoryView: View {
    let onPlay: (TVBoxPlayback, Double) -> Void
    @ObservedObject private var history = TVBoxPlaybackHistory.shared
    @State private var confirmingClear = false

    var body: some View {
        List {
            if history.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("暂无播放记录").font(.headline)
                    Text("从 TVBox 影视源播放后，记录会自动保存在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
            } else {
                ForEach(history.entries) { entry in
                    Button {
                        onPlay(entry.playback, entry.position)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.playback.videoTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(entry.playback.sourceName) · \(entry.playback.episodeName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if entry.duration > 0 {
                                ProgressView(value: min(1, entry.position / entry.duration))
                                Text("上次播放：\(Self.time(entry.position)) / \(Self.time(entry.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("点击继续播放")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.lastPlayed.formatted(date: .numeric, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { history.remove(entry.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .confirmationDialog("清空全部播放历史？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空全部记录", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除播放记录，不会删除已下载的视频。")
        }
    }

    private static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(value)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
