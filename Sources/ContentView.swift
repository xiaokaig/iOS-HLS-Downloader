import SwiftUI
import AVKit
import WebKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var downloader = HLSDownloadManager()
    @StateObject private var directDownloader = DirectVideoDownloadManager()
    @StateObject private var library = BrowserLibraryStore()
    @StateObject private var browserController = BrowserController()
    @State private var selectedTab = 0
    @AppStorage("hlsSniffingEnabled") private var hlsSniffingEnabled = true
    @AppStorage("videoSniffingEnabled") private var videoSniffingEnabled = false
    @AppStorage("adRedirectBlockingEnabled") private var adRedirectBlockingEnabled = false
    @AppStorage("popupBlockingEnabled") private var popupBlockingEnabled = false
    @AppStorage("customAdDomains") private var customAdDomains = ""
    @AppStorage("defaultSearchEngine") private var defaultSearchEngine = "bing"
    @State private var showingBrowserCandidates = false
    @State private var showingBrowsingHistory = false
    @State private var showingBookmarks = false

    // Browser
    @State private var browserAddress = ""
    @State private var candidates: [URL] = []
    @State private var candidateCookies: [String: [HTTPCookie]] = [:]
    @State private var candidateMetadata: [String: String] = [:]

    // Direct download / quality picker
    @State private var directURL = ""
    @State private var pendingURL: URL?
    @State private var pendingCookies: [HTTPCookie] = []
    @State private var variants: [HLSVariant] = []
    @State private var selectedVariantURL: URL?
    @State private var parsedSegmentCount = 0
    @State private var parsedDuration = 0.0
    @State private var parsedIsEndList = false
    @State private var isInspecting = false
    @State private var showingVariants = false
    @State private var errorMessage: String?

    // Local files
    @State private var localFiles: [URL] = []
    @State private var playingURL: URL?
    @State private var directDownloadSourceURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            browserTab
                .tabItem { Label("浏览器", systemImage: "safari") }
                .tag(0)

            downloadsTab
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(1)

            filesTab
                .tabItem { Label("文件", systemImage: "folder") }
                .tag(2)

            settingsTab
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.blue)
        .onAppear {
            refreshFiles()
            AppDiagnostics.shared.log("APP", "ContentView appeared")
        }
        .onChange(of: scenePhase) { phase in
            AppDiagnostics.shared.log("APP", "scenePhase=\(String(describing: phase))")
        }
        .onChange(of: directDownloader.outputURL) { url in
            guard let url else { return }
            library.recordDownload(fileURL: url, sourceURL: directDownloadSourceURL)
            directDownloadSourceURL = nil
            refreshFiles()
        }
        .sheet(isPresented: $showingVariants) {
            variantPicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { playingURL != nil },
            set: { if !$0 { playingURL = nil } }
        )) {
            if let url = playingURL {
                HLSPlayerScreen(url: url).ignoresSafeArea().background(.black)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var browserTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("主页 · 搜索或输入网址", text: $browserAddress)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().submitLabel(.go).onSubmit(loadBrowserAddress)
                    if browserController.isLoading { ProgressView().controlSize(.small) }
                    Button {
                        toggleCurrentBookmark()
                    } label: {
                        Image(systemName: currentPageIsBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .disabled(currentPageURL == nil)
                    Button(action: loadBrowserAddress) { Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)) }
                }
                .padding(.horizontal, 15).frame(height: 48)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().stroke(Color(uiColor: .separator).opacity(0.18)))
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
                ZStack {
                    BrowserView(address: browserAddress, controller: browserController, onCapture: addCandidate,
                                onAddressChange: { value in
                                    browserAddress = value
                                    if let url = URL(string: value) {
                                        library.recordVisit(url: url, title: url.host ?? value)
                                    }
                                }, isSniffingEnabled: hlsSniffingEnabled,
                                isVideoSniffingEnabled: videoSniffingEnabled,
                                isAdRedirectBlockingEnabled: adRedirectBlockingEnabled,
                                isPopupBlockingEnabled: popupBlockingEnabled,
                                customAdDomains: customAdDomains)
                        .id(browserController.webViewID)
                    if browserAddress.isEmpty {
                        VStack(spacing: 24) {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "safari").font(.system(size: 42, weight: .light)).foregroundStyle(.blue)
                                Text("轻装上网").font(.title3.weight(.semibold))
                                Text("搜索，或输入网址开始浏览").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                browserShortcut("百度", icon: "magnifyingglass", url: "https://www.baidu.com")
                                browserShortcut("必应", icon: "sparkle.magnifyingglass", url: "https://www.bing.com")
                                browserShortcut("GitHub", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com")
                                browserShortcut("YouTube", icon: "play.rectangle", url: "https://www.youtube.com")
                            }
                            Spacer(); Spacer()
                        }
                        .padding(.horizontal, 20).background(Color(uiColor: .systemBackground))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 0) {
                    browserTool("chevron.left", disabled: !browserController.canGoBack) { browserController.goBack() }
                    browserTool("chevron.right", disabled: !browserController.canGoForward) { browserController.goForward() }
                    browserTool("house") { browserAddress = ""; browserController.goHome() }
                    Spacer(minLength: 8)
                    browserLibraryTool("历史", symbol: "clock.arrow.circlepath") { showingBrowsingHistory = true }
                    browserLibraryTool("书签", symbol: "bookmark") { showingBookmarks = true }
                    Button { showingBrowserCandidates = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(candidates.isEmpty ? "嗅探" : "嗅探 \(candidates.count)").font(.caption.weight(.medium))
                        }
                        .foregroundStyle(candidates.isEmpty ? Color.secondary : Color.blue)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }
                    browserTool("arrow.clockwise") { browserController.reload() }
                    browserTool("xmark", disabled: !browserController.isLoading) { browserController.stopLoading() }
                }
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 5).background(.ultraThinMaterial)
            }
            .background(Color(uiColor: .systemBackground)).navigationBarHidden(true)
            .sheet(isPresented: $showingBrowserCandidates) {
                NavigationStack {
                    List {
                        if candidates.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                                Text("暂未发现视频").font(.headline)
                                Text("播放网页中的视频后，检测到 HLS 地址会显示在这里。")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                        } else {
                            ForEach(candidates, id: \.absoluteString) { url in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "film").foregroundStyle(.blue)
                                        Text(url.lastPathComponent.isEmpty ? "视频流" : url.lastPathComponent)
                                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Spacer()
                                        if url.pathExtension.lowercased() == "m3u8" && candidateMetadata[candidateKey(url)] != "普通视频直链 · 可复制地址" {
                                            Button("解析") {
                                                showingBrowserCandidates = false
                                                inspect(url, cookies: candidateCookies[candidateKey(url)] ?? [])
                                            }
                                            .buttonStyle(.borderedProminent).controlSize(.small)
                                        }
                                    }
                                    Text(url.host ?? url.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    Text(candidateMetadata[candidateKey(url)] ?? "正在识别播放列表…")
                                        .font(.caption).foregroundStyle(.blue)
                                    HStack(spacing: 16) {
                                        Button { UIPasteboard.general.string = url.absoluteString } label: {
                                            Label("复制地址", systemImage: "doc.on.doc")
                                        }
                                        .font(.caption)
                                        if candidateMetadata[candidateKey(url)] == "普通视频直链 · 可复制地址" {
                                            Button {
                                                showingBrowserCandidates = false
                                                startDirectVideoDownload(url, cookies: candidateCookies[candidateKey(url)] ?? [])
                                            } label: {
                                                Label("下载", systemImage: "arrow.down.circle.fill")
                                            }
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.blue)
                                            .disabled(directDownloader.isDownloading || downloader.isDownloading)
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                    .navigationTitle("视频嗅探").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("关闭") { showingBrowserCandidates = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("清空") {
                                candidates.removeAll()
                                candidateCookies.removeAll()
                                candidateMetadata.removeAll()
                            }.disabled(candidates.isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingBrowsingHistory) { browsingHistorySheet }
            .sheet(isPresented: $showingBookmarks) { browserBookmarksSheet }
        }
    }

    private var browsingHistorySheet: some View {
        NavigationStack {
            Group {
                if library.browsingHistory.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("暂无浏览记录").font(.headline)
                        Text("访问过的网页会自动保存在这里。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(library.browsingHistory) { entry in
                            Button {
                                openLibraryPage(entry.url)
                                showingBrowsingHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(entry.visitedAt.formatted(date: .numeric, time: .shortened))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }.padding(.vertical, 3)
                            }.buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { library.removeBrowsingVisit(entry.id) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("浏览历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { showingBrowsingHistory = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { library.clearBrowsingHistory() }
                        .disabled(library.browsingHistory.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var browserBookmarksSheet: some View {
        NavigationStack {
            Group {
                if library.bookmarks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("还没有书签").font(.headline)
                        Text("浏览网页时点击地址栏旁的书签图标即可收藏。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(library.bookmarks) { bookmark in
                            Button {
                                openLibraryPage(bookmark.url)
                                showingBookmarks = false
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bookmark.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(bookmark.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { library.removeBookmark(bookmark.id) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { showingBookmarks = false }
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func openLibraryPage(_ value: String) {
        guard let url = URL(string: value) else { return }
        browserAddress = url.absoluteString
        browserController.load(url)
    }

    private func browserTool(_ symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 42, height: 38)
        }
        .foregroundStyle(disabled ? .tertiary : .primary).disabled(disabled)
    }

    private func browserLibraryTool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 38)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .foregroundStyle(.primary)
    }

    private func browserShortcut(_ title: String, icon: String, url: String) -> some View {
        Button {
            browserAddress = url
            if let target = URL(string: url) { browserController.load(target) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(.primary)
                    .frame(width: 54, height: 54)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var downloadsTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("直接下载")
                            .font(.title2.bold())
                        Text("粘贴 M3U8 地址，无需先打开网页。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("https://example.com/video.m3u8", text: $directURL, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .lineLimit(1...3)
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Button {
                                if let value = UIPasteboard.general.string {
                                    directURL = value
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.title3)
                                    .frame(width: 42, height: 46)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(action: parseDirectURL) {
                            if isInspecting { ProgressView().frame(maxWidth: .infinity) }
                            else { Label("解析地址", systemImage: "text.magnifyingglass").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInspecting || downloader.isDownloading || directDownloader.isDownloading)
                    }
                    .padding()
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(uiColor: .separator).opacity(0.25)))

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("当前任务")
                                .font(.title3.bold())
                            Spacer()
                            if downloader.isDownloading {
                                Label("进行中", systemImage: "arrow.down.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.blue)
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: downloader.isDownloading || directDownloader.isDownloading ? "arrow.down.doc.fill" : "doc")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 44, height: 44)
                                .background(Color.blue.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(directDownloader.isDownloading || directDownloader.outputURL != nil
                                     ? directDownloader.status : downloader.status)
                                    .font(.headline)
                                if directDownloader.isDownloading {
                                    ProgressView(value: directDownloader.progress)
                                    Text(directDownloader.progress, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else if downloader.isDownloading {
                                    ProgressView(value: downloader.progress)
                                    Text(downloader.progress, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else if let output = downloader.outputURL {
                                    Text(output.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("尚无下载任务")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        if let warning = downloader.conversionWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let output = directDownloader.outputURL {
                            ShareLink(item: output) {
                                Label("分享 / 导出视频", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else if let output = downloader.outputURL {
                            ShareLink(item: output) {
                                Label("分享 / 导出视频", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(uiColor: .separator).opacity(0.25)))

                    Label("提示：当前版本一次处理一个下载任务；后台自动恢复和暂停/继续功能尚未接入。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var filesTab: some View {
        NavigationStack {
            Group {
                if localFiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("还没有下载文件")
                            .font(.headline)
                        Text("完成下载的视频会显示在这里。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    List {
                        ForEach(localFiles, id: \.absoluteString) { url in
                            HStack(spacing: 12) {
                                Image(systemName: "film")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                    .frame(width: 42, height: 42)
                                    .background(Color.blue.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(fileSize(url)) · \(formattedFileDate(url))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    playingURL = url
                                } label: {
                                    Image(systemName: "play.circle")
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 5)
                        }
                        .onDelete(perform: deleteFiles)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { refreshFiles() }
                }
            }
            .navigationTitle("已下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: refreshFiles) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            List {
                Section("浏览器设置") {
                    Toggle("HLS 视频嗅探", isOn: $hlsSniffingEnabled)
                    Toggle("普通视频嗅探（MP4 等）", isOn: $videoSniffingEnabled)
                    Text(videoSniffingEnabled ? "已开启：识别 MP4、M4V、MOV、WebM 直链及 video/* 响应。" : "已关闭：不检测普通视频直链，不影响 HLS 嗅探。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(hlsSniffingEnabled ? "已开启：浏览网页时自动检测 HLS 视频地址。" : "已关闭：不注入 HLS 嗅探脚本，普通网页仍可正常浏览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("广告页面跳转拦截", isOn: $adRedirectBlockingEnabled)
                    Text("拦截内置广告域名及自定义域名的顶层页面跳转，不拦截普通网页资源请求。默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("弹窗 / 新窗口拦截", isOn: $popupBlockingEnabled)
                    Text("阻止网页通过 window.open 或新窗口链接打开页面。默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("地址栏与搜索") {
                    Picker("默认搜索引擎", selection: $defaultSearchEngine) {
                        Text("必应").tag("bing")
                        Text("百度").tag("baidu")
                        Text("Google").tag("google")
                        Text("DuckDuckGo").tag("duckduckgo")
                    }
                }
                Section("广告域名规则") {
                    Text("内置规则包含常见广告跳转域名。可在下面逐行添加域名，仅拦截该域名及其子域名。不要填写 https:// 或路径。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $customAdDomains)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("每行一个域名")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清空自定义规则", role: .destructive) { customAdDomains = "" }
                            .font(.caption)
                    }
                }
                Section("当前加载状态") {
                    Text(browserController.diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        browserController.rebuildWebView()
                    } label: {
                        Label("重建浏览器", systemImage: "arrow.clockwise")
                    }
                }
                Section("完整诊断日志") {
                    Text(AppDiagnostics.shared.recentText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(300)
                    Button {
                        UIPasteboard.general.string = AppDiagnostics.shared.copyRecent(maxLines: 200)
                    } label: {
                        Label("复制最近日志（最多200行）", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: AppDiagnostics.shared.exportURL()) {
                        Label("导出日志文件", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        AppDiagnostics.shared.refresh()
                    } label: {
                        Label("刷新日志", systemImage: "arrow.clockwise")
                    }
                    Text("从应用启动开始记录，最多约 2MB；相同事件自动合并；复制仅包含最近 200 行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("下载设置") {
                    LabeledContent("分片并发", value: "6 路")
                    LabeledContent("失败重试", value: "最多 3 次")
                    LabeledContent("输出位置", value: "App 文稿目录")
                }
                Section("支持情况") {
                    Label("HLS VOD 播放列表", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("AES-128 加密", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("TS 兼容播放（VLC）", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Label("TS 无损封装 MP4（尽力尝试）", systemImage: "checkmark.circle")
                        .foregroundStyle(.primary)
                    Label("直播 / DRM / SAMPLE-AES", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("应用", value: "HLS 下载器")
                    LabeledContent("版本", value: "界面改版预览")
                }
            }
            .navigationTitle("设置")
        }
    }

    private var variantPicker: some View {
        NavigationStack {
            List {
                if variants.isEmpty {
                    Section("播放列表信息") {
                        LabeledContent("分片数量", value: "\(parsedSegmentCount)")
                        LabeledContent("时长", value: formattedDuration(parsedDuration))
                        LabeledContent("类型", value: parsedIsEndList ? "VOD 点播" : "非完整列表")
                    }
                } else {
                    Section("选择清晰度") {
                        ForEach(variants) { variant in
                            Button { selectedVariantURL = variant.url } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(variant.resolution ?? "清晰度未知").font(.headline)
                                        Text(variant.bandwidth > 0 ? String(format: "%.2f Mbps", Double(variant.bandwidth) / 1_000_000) : "码率未知")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedVariantURL == variant.url ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedVariantURL == variant.url ? .blue : .secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: startPendingDownload) {
                    Label("开始下载", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).padding()
                    .disabled(downloader.isDownloading || directDownloader.isDownloading || (!parsedIsEndList && variants.isEmpty))
                    .background(.regularMaterial)
            }
            .navigationTitle("视频信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { showingVariants = false } } }
        }
    }

    private func candidateKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? url.absoluteString
    }

    private func addCandidate(_ url: URL, cookies: [HTTPCookie], isDirectVideoResponse: Bool = false) {
        let key = candidateKey(url)
        candidateCookies[key] = cookies
        guard !candidates.contains(where: { candidateKey($0) == key }) else { return }
        candidates.insert(url, at: 0)
        let ext = url.pathExtension.lowercased()
        let isDirectVideo = isDirectVideoResponse || ["mp4", "m4v", "mov", "webm"].contains(ext)
        candidateMetadata[key] = isDirectVideo ? "普通视频直链 · 可复制地址" : "正在识别播放列表…"
        if candidates.count > 20 {
            let removed = candidates.suffix(from: 20)
            for item in removed {
                let removedKey = candidateKey(item)
                candidateCookies.removeValue(forKey: removedKey)
                candidateMetadata.removeValue(forKey: removedKey)
            }
            candidates = Array(candidates.prefix(20))
        }

        guard !isDirectVideo else { return }

        Task {
            do {
                let result = try await downloader.inspectPlaylist(url, cookies: cookies)
                guard candidates.contains(where: { candidateKey($0) == key }) else { return }
                if !result.variants.isEmpty {
                    candidateMetadata[key] = "主播放列表 · \(result.variants.count) 个清晰度"
                    for variant in result.variants {
                        let variantKey = candidateKey(variant.url)
                        let resolution = variant.resolution ?? "分辨率未知"
                        let bitrate = variant.bandwidth > 0
                            ? String(format: "%.2f Mbps", Double(variant.bandwidth) / 1_000_000)
                            : "码率未知"
                        candidateMetadata[variantKey] = "\(resolution) · \(bitrate)"
                    }
                } else if result.segmentCount > 0 {
                    if candidateMetadata[key] == nil || candidateMetadata[key] == "正在识别播放列表…" {
                        candidateMetadata[key] = "媒体播放列表 · \(result.segmentCount) 个分片"
                    }
                } else if candidateMetadata[key] == nil || candidateMetadata[key] == "正在识别播放列表…" {
                    candidateMetadata[key] = "播放列表已读取，未发现清晰度信息"
                }
            } catch {
                if candidates.contains(where: { candidateKey($0) == key }),
                   candidateMetadata[key] == nil || candidateMetadata[key] == "正在识别播放列表…" {
                    candidateMetadata[key] = "暂时无法读取播放列表"
                }
            }
        }
    }

    private var currentPageURL: URL? {
        browserController.webView?.url ?? URL(string: browserAddress)
    }

    private var currentPageIsBookmarked: Bool {
        guard let url = currentPageURL else { return false }
        return library.isBookmarked(url)
    }

    private func toggleCurrentBookmark() {
        guard let url = currentPageURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let title = browserController.webView?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (title?.isEmpty == false ? title! : (url.host ?? url.absoluteString))
        library.addBookmark(url: url, title: value)
    }

    private func startDirectVideoDownload(_ url: URL, cookies: [HTTPCookie]) {
        guard !downloader.isDownloading, !directDownloader.isDownloading else {
            errorMessage = "当前已有下载任务，请完成后再开始。"
            return
        }
        directDownloadSourceURL = url
        directDownloader.start(url: url, cookies: cookies, referrer: currentPageURL)
        selectedTab = 1
    }

    private func formattedFileDate(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func loadBrowserAddress() {
        let raw = browserAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let hasWhitespace = raw.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let normalized = raw.contains("://") ? raw : "https://" + raw
        if !hasWhitespace, let url = URL(string: normalized),
           let host = url.host, host.contains("."), !host.hasPrefix(".") {
            browserAddress = url.absoluteString
            browserController.load(url)
            return
        }
        let query = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        let prefix: String
        switch defaultSearchEngine {
        case "baidu": prefix = "https://www.baidu.com/s?wd="
        case "google": prefix = "https://www.google.com/search?q="
        case "duckduckgo": prefix = "https://duckduckgo.com/?q="
        default: prefix = "https://www.bing.com/search?q="
        }
        if let url = URL(string: prefix + query) {
            browserAddress = url.absoluteString
            browserController.load(url)
        }
    }

    private func parseDirectURL() {
        let raw = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS M3U8 地址。"
            return
        }
        inspect(url, cookies: [], presentSheet: true)
    }

    private func inspect(_ url: URL, cookies: [HTTPCookie], presentSheet: Bool = true) {
        pendingURL = url
        pendingCookies = cookies
        selectedVariantURL = nil
        variants = []
        parsedSegmentCount = 0
        parsedDuration = 0
        parsedIsEndList = false
        errorMessage = nil
        isInspecting = true
        Task {
            do {
                let result = try await downloader.inspectPlaylist(url, cookies: cookies)
                await MainActor.run {
                    variants = result.variants
                    parsedSegmentCount = result.segmentCount
                    parsedDuration = result.duration
                    parsedIsEndList = result.isEndList
                    selectedVariantURL = result.variants.first?.url
                    isInspecting = false
                    if presentSheet { showingVariants = true }
                }
            } catch {
                await MainActor.run { isInspecting = false; errorMessage = error.localizedDescription }
            }
        }
    }

    private func startPendingDownload() {
        guard let url = selectedVariantURL ?? pendingURL else { return }
        showingVariants = false
        directURL = ""
        pendingURL = nil
        selectedVariantURL = nil
        variants = []
        startDownload(url, cookies: pendingCookies)
        pendingCookies = []
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private func startDownload(_ url: URL, cookies: [HTTPCookie]) {
        Task {
            do {
                let output = try await downloader.start(url: url, cookies: cookies)
                await MainActor.run {
                    library.recordDownload(fileURL: output, sourceURL: url)
                    refreshFiles()
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func refreshFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        localFiles = urls.filter { ["mp4", "ts", "m4v", "mov", "webm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        for file in localFiles where !library.history.contains(where: { $0.fileURL == file.absoluteString }) {
            library.recordDownload(fileURL: file, sourceURL: nil)
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            let url = localFiles[index]
            try? FileManager.default.removeItem(at: url)
            if let entry = library.history.first(where: { $0.fileURL == url.absoluteString }) {
                library.removeHistory(entry.id)
            }
        }
        refreshFiles()
    }
}
