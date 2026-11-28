import SwiftUI

struct TVBoxCatalogView: View {
    let site: TVBoxSite
    let onPlay: (TVBoxPlayback) -> Void

    @State private var keyword = ""
    @State private var searchResults: [TVBoxVideo] = []
    @State private var categories: [TVBoxCategory] = []
    @State private var catalogVideos: [TVBoxVideo] = []
    @State private var selectedCategoryID: String?
    @State private var isSearching = false
    @State private var isLoadingCatalog = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var page = 1

    private var visibleVideos: [TVBoxVideo] { hasSearched ? searchResults : catalogVideos }

    var body: some View {
        List {
            Section("搜索") {
                HStack(spacing: 8) {
                    TextField("搜索影视名称", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: {
                        if isSearching { ProgressView() } else { Image(systemName: "magnifyingglass") }
                    }
                    .disabled(isSearching || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasSearched {
                        Button("取消") {
                            hasSearched = false
                            searchResults = []
                            errorMessage = nil
                        }
                        .font(.caption)
                    }
                }
            }

            if !hasSearched {
                Section("片单分类") {
                    if categories.isEmpty {
                        Text(isLoadingCatalog ? "正在读取分类…" : "该站点未提供分类，显示全部片单")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                categoryButton(title: "全部", id: nil)
                                ForEach(categories) { category in
                                    categoryButton(title: category.name, id: category.id)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }

            if let errorMessage {
                Section("提示") {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                    if !hasSearched {
                        Button("重新加载片单") { Task { await loadCatalog(categoryID: selectedCategoryID, page: 1) } }
                    }
                }
            }

            Section(hasSearched ? "搜索结果" : "视频片单") {
                if (hasSearched && isSearching || !hasSearched && isLoadingCatalog) && visibleVideos.isEmpty {
                    HStack { Spacer(); ProgressView(hasSearched ? "正在搜索…" : "正在加载片单…"); Spacer() }
                } else if visibleVideos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(hasSearched ? "没有搜索结果" : "暂无片单")
                            .font(.headline)
                        Text(hasSearched ? "换一个关键词试试。" : "可以切换分类，或使用上方搜索。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(visibleVideos) { video in
                        NavigationLink {
                            TVBoxVideoDetailView(site: site, video: video, onPlay: onPlay)
                        } label: {
                            videoRow(video)
                        }
                    }
                    HStack {
                        Button("上一页") {
                            if hasSearched { Task { await search(page: max(1, page - 1)) } }
                            else { Task { await loadCatalog(categoryID: selectedCategoryID, page: max(1, page - 1)) } }
                        }
                        .disabled(page <= 1 || isSearching || isLoadingCatalog)
                        Spacer()
                        Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("下一页") {
                            if hasSearched { Task { await search(page: page + 1) } }
                            else { Task { await loadCatalog(categoryID: selectedCategoryID, page: page + 1) } }
                        }
                        .disabled(visibleVideos.count < 10 || isSearching || isLoadingCatalog)
                    }
                }
            }
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCatalog(categoryID: nil, page: 1) }
    }

    private func categoryButton(title: String, id: String?) -> some View {
        Button {
            guard selectedCategoryID != id else { return }
            hasSearched = false
            searchResults = []
            selectedCategoryID = id
            Task { await loadCatalog(categoryID: id, page: 1) }
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(selectedCategoryID == id ? .white : .primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selectedCategoryID == id ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func videoRow(_ video: TVBoxVideo) -> some View {
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
                Text("查看详情和选集").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func search(page targetPage: Int = 1) async {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        hasSearched = true
        searchResults = []
        defer { isSearching = false }
        do {
            searchResults = try await TVBoxAPIClient.search(site: site, keyword: term, page: targetPage)
            page = targetPage
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadCatalog(categoryID: String?, page targetPage: Int) async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        errorMessage = nil
        defer { isLoadingCatalog = false }
        do {
            let result = try await TVBoxAPIClient.catalog(site: site, categoryID: categoryID, page: targetPage)
            if targetPage == 1 && categories.isEmpty { categories = result.categories }
            catalogVideos = result.videos
            page = targetPage
            selectedCategoryID = categoryID
        } catch {
            errorMessage = "片单加载失败：\(error.localizedDescription)"
        }
    }
}

struct TVBoxVideoDetailView: View {
    let site: TVBoxSite
    let video: TVBoxVideo
    let onPlay: (TVBoxPlayback) -> Void

    @State private var detail: TVBoxVideoDetail?
    @State private var isLoading = false
    @State private var isStartingPlayback = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text(video.name).font(.headline)
                if !displayedContent.isEmpty {
                    Text(displayedContent).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if isLoading {
                Section("播放线路") {
                    HStack { ProgressView(); Text("正在读取线路和选集，请稍候…").font(.caption) }
                }
            }

            if let errorMessage {
                Section("状态") {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                    Button("重新读取线路") { startLoading() }
                }
            }

            if let detail, detail.playSources.isEmpty {
                Section("播放线路") {
                    Text("站点没有返回可识别的播放地址。部分站点需要 Spider 或专用解析器，当前版本暂不执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let detail {
                ForEach(detail.playSources) { source in
                    Section(source.name) {
                        ForEach(source.episodes) { episode in
                            Button {
                                guard !isStartingPlayback else { return }
                                guard let url = URL(string: episode.url),
                                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                                    errorMessage = TVBoxSourceError.noPlayableAddress.localizedDescription
                                    return
                                }
                                isStartingPlayback = true
                                errorMessage = nil
                                onPlay(TVBoxPlayback(videoTitle: video.name, sourceName: source.name, episodeName: episode.name, url: url))
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.blue)
                                    Text(episode.name).foregroundStyle(.primary)
                                    Spacer()
                                    if isStartingPlayback { ProgressView() }
                                    else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isStartingPlayback)
                        }
                    }
                }
            }
        }
        .navigationTitle("影视详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { startLoading() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private var displayedContent: String {
        detail?.video.content.isEmpty == false ? detail!.video.content : video.content
    }

    @MainActor
    private func startLoading() {
        guard !isLoading else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        detail = nil
        loadTask = Task {
            let started = Date()
            do {
                let result = try await TVBoxAPIClient.detail(site: site, video: video)
                guard !Task.isCancelled else { return }
                detail = result
                // Prewarm only the first episode on each route; avoid opening dozens of streams at once.
                for source in result.playSources.prefix(4) {
                    if let firstEpisode = source.episodes.first, let url = URL(string: firstEpisode.url) {
                        TVBoxPlaybackPreloader.shared.preload(url)
                    }
                }
                AppDiagnostics.shared.log("TVBOX", "详情加载完成 site=\(site.name) video=\(video.name) routes=\(result.playSources.count) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "线路读取失败：\(error.localizedDescription)"
                AppDiagnostics.shared.log("TVBOX", "详情加载失败 video=\(video.name) error=\(error.localizedDescription)")
            }
            if !Task.isCancelled { isLoading = false }
        }
    }
}
