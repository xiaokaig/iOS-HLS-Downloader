import SwiftUI

private struct TVBoxSourceHistoryEntry: Codable, Identifiable {
    let id: String
    let url: String
    let title: String
    let lastUsed: Date
}

struct TVBoxSourceView: View {
    let downloadQueue: DownloadQueueManager
    @AppStorage("tvboxSourceHistory") private var sourceHistoryJSON = "[]"
    @AppStorage("tvboxCurrentSourceAddress") private var sourceAddress = ""
    @AppStorage("tvboxParsedSourceCache") private var parsedSourceCacheJSON = ""
    @State private var activePlayback: TVBoxPlayback?
    @State private var activeResumePosition = 0.0
    @State private var parsedSource: TVBoxParsedSource?
    @State private var isLoading = false
    @State private var statusMessage = "首次使用请粘贴 TVBox JSON 源地址。"
    @State private var sourceHost = ""

    private var sourceHistory: [TVBoxSourceHistoryEntry] {
        guard let data = sourceHistoryJSON.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        guard let entries = try? decoder.decode([TVBoxSourceHistoryEntry].self, from: data) else { return [] }
        let sortedEntries = entries.sorted { first, second in
            first.lastUsed > second.lastUsed
        }
        return sortedEntries
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Label("当前影视源", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                        Spacer()
                        Menu {
                            if sourceHistory.isEmpty {
                                Text("暂无源历史")
                            } else {
                                Section("最近使用") {
                                    ForEach(sourceHistory) { entry in
                                        Button {
                                            sourceAddress = entry.url
                                            statusMessage = "已填入历史源地址；点击读取按钮才会切换。"
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.title)
                                                Text(entry.url).font(.caption2).lineLimit(1)
                                            }
                                        }
                                    }
                                }
                                Section("管理历史") {
                                    ForEach(sourceHistory) { entry in
                                        Button(role: .destructive) {
                                            removeHistoryEntry(entry.id)
                                        } label: {
                                            Label("删除：\\(entry.title)", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("历史源", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        .accessibilityLabel("历史影视源")
                    }

                    Text("源地址")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("粘贴 TVBox JSON 源地址", text: $sourceAddress, axis: .vertical)
                        .font(.system(.subheadline, design: .rounded))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    Button {
                        Task { await importSource() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView().tint(.white) }
                            Label(isLoading ? "正在读取影视源…" : "读取并切换源", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isLoading || sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))

                NavigationLink {
                    TVBoxPlaybackHistoryView { playback, position in
                        activePlayback = playback
                        activeResumePosition = position
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.title2).foregroundStyle(Color.accentColor)
                            .frame(width: 42, height: 42)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("播放历史").font(.subheadline.weight(.semibold))
                            Text("继续上次观看的位置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\\(TVBoxPlaybackHistory.shared.entries.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)

                if let parsedSource {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(parsedSource.title).font(.title3.weight(.bold))
                            Spacer()
                            Text("已加载").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            sourceMetric("站点", value: "\\(parsedSource.siteCount)")
                            sourceMetric("解析器", value: "\\(parsedSource.parseCount)")
                            sourceMetric("直播", value: "\\(parsedSource.liveCount)")
                        }
                        if !sourceHost.isEmpty {
                            Label(sourceHost, systemImage: "server.rack")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let spider = parsedSource.spiderReference, !spider.isEmpty {
                            Text("Spider：\\(spider)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("标准 XML/JSON CMS 支持分类片单、搜索、详情和直链播放。Spider、扩展 API、直播及解析器暂不执行。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("站点列表").font(.headline)
                            Spacer()
                            Text("\\(parsedSource.sites.count) 个站点").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(parsedSource.sites) { site in
                            if (site.type == 0 || site.type == 1) && site.searchable {
                                NavigationLink {
                                    TVBoxCatalogView(site: site, onPlay: { playback in
                                        activeResumePosition = 0
                                        activePlayback = playback
                                        TVBoxPlaybackHistory.shared.record(playback, position: 0, duration: 0)
                                    })
                                } label: {
                                    siteRow(site, enabled: true)
                                        .padding(12)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            } else {
                                siteRow(site, enabled: false)
                                    .padding(12)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("TVBox 影视源")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if parsedSource == nil, !parsedSourceCacheJSON.isEmpty,
               let data = parsedSourceCacheJSON.data(using: .utf8),
               let cached = try? JSONDecoder().decode(TVBoxParsedSource.self, from: data) {
                parsedSource = cached
                sourceHost = URL(string: sourceAddress)?.host ?? ""
                statusMessage = "已恢复上次成功解析的影视源（\\(cached.siteCount) 个站点）。"
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { activePlayback != nil },
            set: { if !$0 { activePlayback = nil } }
        )) {
            if let playback = activePlayback {
                HLSPlayerScreen(
                    url: playback.url,
                    title: playback.videoTitle,
                    subtitle: "\\(playback.sourceName) · \\(playback.episodeName)",
                    preloadedAsset: TVBoxPlaybackPreloader.shared.asset(for: playback.url),
                    tvboxPlayback: playback,
                    downloadQueue: downloadQueue,
                    resumePosition: activeResumePosition,
                    onPlaybackProgress: { item, position, duration in
                        TVBoxPlaybackHistory.shared.record(item, position: position, duration: duration)
                    },
                    onClose: { activePlayback = nil; activeResumePosition = 0 }
                )
                .background(.black)
            }
        }
    }

    private func sourceMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func siteRow(_ site: TVBoxSite, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(site.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(site.typeName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if !site.api.isEmpty {
                Text(site.api).font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
            }
            Text(enabled ? "浏览分类片单、搜索影视和查看详情" : site.compatibilityDescription)
                .font(.caption).foregroundStyle(enabled ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @MainActor
    private func importSource(address: String? = nil) async {
        let rawAddress = (address ?? sourceAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddress.isEmpty, !isLoading else { return }
        isLoading = true
        statusMessage = "正在下载并检查影视源…"
        defer { isLoading = false }
        do {
            let (source, finalURL) = try await TVBoxSourceParser.fetch(rawAddress)
            parsedSource = source
            sourceHost = finalURL.host ?? ""
            sourceAddress = rawAddress
            if let data = try? JSONEncoder().encode(source), let cached = String(data: data, encoding: .utf8) {
                parsedSourceCacheJSON = cached
            }
            saveHistory(url: rawAddress, title: source.title)
            statusMessage = "读取成功：\(source.siteCount) 个站点，已加入源历史。"
        } catch {
            statusMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    private func saveHistory(url: String, title: String) {
        var entries = sourceHistory.filter { $0.url != url }
        entries.insert(TVBoxSourceHistoryEntry(id: UUID().uuidString, url: url, title: title, lastUsed: Date()), at: 0)
        entries = Array(entries.prefix(30))
        if let data = try? JSONEncoder().encode(entries), let value = String(data: data, encoding: .utf8) {
            sourceHistoryJSON = value
        }
    }

    private func removeHistoryEntry(_ id: String) {
        let entries = sourceHistory.filter { $0.id != id }
        if let data = try? JSONEncoder().encode(entries), let value = String(data: data, encoding: .utf8) {
            sourceHistoryJSON = value
        }
    }
}
