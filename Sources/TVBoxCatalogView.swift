import SwiftUI

struct TVBoxCatalogView: View {
    let site: TVBoxSite
    let onPlay: (URL) -> Void

    @State private var keyword = ""
    @State private var results: [TVBoxVideo] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var page = 1

    var body: some View {
        List {
            Section("搜索影视") {
                HStack(spacing: 8) {
                    TextField("输入影视名称", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search(reset: true) } }
                    Button {
                        Task { await search(reset: true) }
                    } label: {
                        if isSearching { ProgressView() }
                        else { Image(systemName: "magnifyingglass") }
                    }
                    .disabled(isSearching || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            if isSearching && results.isEmpty {
                HStack { Spacer(); ProgressView("正在搜索…"); Spacer() }
            } else if results.isEmpty && hasSearched {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("没有搜索结果").font(.headline)
                    Text("换一个关键词试试。").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if !results.isEmpty {
                Section("搜索结果 · \(results.count)") {
                    ForEach(results) { video in
                        NavigationLink {
                            TVBoxVideoDetailView(site: site, video: video, onPlay: onPlay)
                        } label: {
                            HStack(spacing: 12) {
                                if let url = URL(string: video.imageURL, relativeTo: URL(string: site.api))?.absoluteURL, !video.imageURL.isEmpty {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                                    }
                                    .frame(width: 64, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.12))
                                        .frame(width: 64, height: 88)
                                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    if !video.remarks.isEmpty {
                                        Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Text("点开查看详情和选集").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("上一页") { Task { await search(reset: false, targetPage: max(1, page - 1)) } }
                            .disabled(isSearching || page <= 1)
                        Spacer()
                        Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("下一页") { Task { await search(reset: false, targetPage: page + 1) } }
                            .disabled(isSearching || results.count < 10)
                    }
                }
            }
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func search(reset: Bool, targetPage: Int? = nil) async {
        let nextPage = targetPage ?? (reset ? 1 : page)
        isSearching = true
        errorMessage = nil
        if reset { results = []; hasSearched = false }
        defer { isSearching = false }
        do {
            let found = try await TVBoxAPIClient.search(site: site, keyword: keyword, page: nextPage)
            results = found
            page = nextPage
            hasSearched = true
        } catch {
            errorMessage = error.localizedDescription
            hasSearched = true
        }
    }
}

struct TVBoxVideoDetailView: View {
    let site: TVBoxSite
    let video: TVBoxVideo
    let onPlay: (URL) -> Void

    @State private var detail: TVBoxVideoDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text(video.name).font(.headline)
                if !displayedContent.isEmpty {
                    Text(displayedContent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading {
                Section { HStack { Spacer(); ProgressView("正在读取详情和播放线路…"); Spacer() } }
            }

            if let errorMessage {
                Section("读取失败") {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                    Button("重试") { Task { await loadDetail() } }
                }
            }

            if let detail, detail.playSources.isEmpty {
                Section("播放线路") {
                    Text("站点没有返回可识别的播放地址。部分站点需要 Spider 或解析器，当前版本暂不执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let detail {
                ForEach(detail.playSources) { source in
                    Section(source.name) {
                        ForEach(source.episodes) { episode in
                            Button {
                                guard let url = URL(string: episode.url),
                                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                                    errorMessage = TVBoxSourceError.noPlayableAddress.localizedDescription
                                    return
                                }
                                onPlay(url)
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.blue)
                                    Text(episode.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("影视详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
    }

    private var displayedContent: String {
        let value = detail?.video.content.isEmpty == false ? detail!.video.content : video.content
        return value
    }

    @MainActor
    private func loadDetail() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            detail = try await TVBoxAPIClient.detail(site: site, video: video)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
