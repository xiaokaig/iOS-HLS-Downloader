import SwiftUI

private struct TVBoxSourceHistoryEntry: Codable, Identifiable {
    let id: String
    let url: String
    let title: String
    let lastUsed: Date
}

struct TVBoxSourceView: View {
    @AppStorage("tvboxSourceHistory") private var sourceHistoryJSON = "[]"
    @State private var sourceAddress = ""
    @State private var parsedSource: TVBoxParsedSource?
    @State private var isLoading = false
    @State private var statusMessage = "首次使用请粘贴 TVBox JSON 源地址。"
    @State private var sourceHost = ""

    let onPlay: (TVBoxPlayback) -> Void

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
                TextField("粘贴 TVBox JSON 源地址", text: $sourceAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                if sourceHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("暂无源历史").font(.headline)
                        Text("成功导入的影视源会保存在这里。").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    ForEach(sourceHistory) { entry in
                        Button {
                            sourceAddress = entry.url
                            Task { await importSource(address: entry.url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(entry.lastUsed.formatted(date: .numeric, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { removeHistoryEntry(entry.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("源历史记录（\(sourceHistory.count)）")
            } footer: {
                Text("点击历史记录即可重新读取该源。首次安装不预置任何影视源。")
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
                                TVBoxCatalogView(site: site, onPlay: onPlay)
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
