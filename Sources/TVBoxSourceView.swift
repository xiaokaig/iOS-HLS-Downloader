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
        List {
            Section("添加影视源") {
                HStack(spacing: 8) {
                    TextField("粘贴 TVBox JSON 源地址", text: $sourceAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Menu {
                        if sourceHistory.isEmpty {
                            Text("暂无源历史")
                        } else {
                            ForEach(sourceHistory) { entry in
                                Button {
                                    sourceAddress = entry.url
                                    statusMessage = "已填入历史源地址，点击「读取并保存源」开始读取。"
                                } label: { Label(entry.title, systemImage: "clock") }
                            }
                            Divider()
                            ForEach(sourceHistory) { entry in
                                Button(role: .destructive) { removeHistoryEntry(entry.id) } label: {
                                    Label("删除：\(entry.title)", systemImage: "trash")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.title3).frame(width: 34, height: 38)
                    }
                    .accessibilityLabel("选择或管理历史源")
                }
                Button {
                    Task { await importSource() }
                } label: {
                    HStack {
                        if isLoading { ProgressView() }
                        Label(isLoading ? "正在读取…" : "读取并保存源", systemImage: "arrow.down.doc")
                    }
                }
                .disabled(isLoading || sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    TVBoxPlaybackHistoryView { playback, position in
                        activePlayback = playback
                        activeResumePosition = position
                    }
                } label: {
                    Label("播放历史", systemImage: "play.rectangle.on.rectangle")
                }
                .badge(TVBoxPlaybackHistory.shared.entries.count)
            }

            if let parsedSource {
                Section {
                    LabeledContent("站点数量", value: "\(parsedSource.siteCount)")
                    LabeledContent("解析器", value: "\(parsedSource.parseCount)")
                    LabeledContent("直播配置", value: "\(parsedSource.liveCount)")
                    if let spider = parsedSource.spiderReference, !spider.isEmpty {
                        LabeledContent("Spider 依赖", value: spider)
                    }
                    if !sourceHost.isEmpty { LabeledContent("来源主机", value: sourceHost) }
                } header: {
                    Text("当前源：\(parsedSource.title)")
                } footer: {
                    Text("标准 XML/JSON CMS 支持分类片单、搜索、详情和直链播放。Spider、扩展 API、直播及解析器暂不执行。")
                }

                Section("站点列表（\(parsedSource.sites.count)）") {
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
                            }
                        } else {
                            siteRow(site, enabled: false)
                        }
                    }
                }
            }
        }
         .navigationTitle("TVBox 影视源")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if parsedSource == nil, !parsedSourceCacheJSON.isEmpty,
               let data = parsedSourceCacheJSON.data(using: .utf8),
               let cached = try? JSONDecoder().decode(TVBoxParsedSource.self, from: data) {
                parsedSource = cached
                sourceHost = URL(string: sourceAddress)?.host ?? ""
                statusMessage = "已恢复上次成功解析的影视源（\(cached.siteCount) 个站点）。"
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
                    subtitle: "\(playback.sourceName) · \(playback.episodeName)",
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
            parsedSource = nil
            sourceHost = ""
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
