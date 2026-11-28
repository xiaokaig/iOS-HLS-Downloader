import SwiftUI

struct TVBoxSourceView: View {
    @AppStorage("tvboxLastSourceURL") private var savedSourceURL = "https://clun.top/fun.json"
    @State private var sourceAddress = "https://clun.top/fun.json"
    @State private var parsedSource: TVBoxParsedSource?
    @State private var isLoading = false
    @State private var statusMessage = "导入 JSON 源后，将显示站点及协议类型。"
    @State private var sourceHost = ""

    let onPlay: (URL) -> Void

    var body: some View {
        List {
            Section("导入源") {
                TextField("TVBox JSON 地址", text: $sourceAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await importSource() }
                } label: {
                    HStack {
                        if isLoading { ProgressView() }
                        Label(isLoading ? "正在读取…" : "读取并解析", systemImage: "arrow.down.doc")
                    }
                }
                .disabled(isLoading || sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let parsedSource {
                Section {
                    LabeledContent("配置名称", value: parsedSource.title)
                    LabeledContent("站点数量", value: "\(parsedSource.siteCount)")
                    LabeledContent("解析器", value: "\(parsedSource.parseCount)")
                    LabeledContent("直播配置", value: "\(parsedSource.liveCount)")
                    if let spider = parsedSource.spiderReference, !spider.isEmpty {
                        LabeledContent("Spider 依赖", value: spider)
                    }
                    if !sourceHost.isEmpty {
                        LabeledContent("来源主机", value: sourceHost)
                    }
                } header: {
                    Text("解析结果")
                } footer: {
                    Text("支持标准 XML/JSON CMS 站点的搜索、详情和直链播放。Spider、扩展 API、直播及解析器暂不执行。")
                }

                Section("站点列表（\(parsedSource.sites.count)）") {
                    ForEach(parsedSource.sites) { site in
                        if site.type == 0 || site.type == 1 {
                            NavigationLink {
                                TVBoxCatalogView(site: site, onPlay: onPlay)
                            } label: {
                                siteRow(site, enabled: site.searchable)
                            }
                            .disabled(!site.searchable)
                        } else {
                            siteRow(site, enabled: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("TVBox 源解析")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !savedSourceURL.isEmpty { sourceAddress = savedSourceURL }
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
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if !site.api.isEmpty {
                Text(site.api)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Text(enabled ? site.compatibilityDescription : (site.type == 3 ? site.compatibilityDescription : "该站点在配置中标记为不可搜索"))
                .font(.caption)
                .foregroundStyle(enabled ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @MainActor
    private func importSource() async {
        isLoading = true
        statusMessage = "正在下载并检查 JSON…"
        defer { isLoading = false }
        do {
            let (source, finalURL) = try await TVBoxSourceParser.fetch(sourceAddress)
            parsedSource = source
            sourceHost = finalURL.host ?? ""
            savedSourceURL = sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "解析成功：识别到 \(source.siteCount) 个站点。点选 XML/JSON CMS 站点即可搜索。"
        } catch {
            parsedSource = nil
            sourceHost = ""
            statusMessage = "解析失败：\(error.localizedDescription)"
        }
    }
}
