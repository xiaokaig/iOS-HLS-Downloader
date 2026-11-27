import SwiftUI
import AVKit
import WebKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var downloader = HLSDownloadManager()
    @StateObject private var library = BrowserLibraryStore()
    @StateObject private var tabManager = BrowserTabManager()
    @StateObject private var downloadQueue = DownloadQueueManager()
    @StateObject private var alistUploader = AListUploadManager()
    private var browserController: BrowserController { tabManager.activeController }
    @State private var showingBrowserMenu = false
    @State private var showingDownloads = false
    @State private var showingFiles = false
    @State private var showingTabOverview = false
    @State private var tabPreviews: [UUID: UIImage] = [:]
    @AppStorage("browserDesktopMode") private var browserDesktopMode = false
    @AppStorage("browserStripMobilePrefix") private var browserStripMobilePrefix = false
    @AppStorage("browserZoomLevel") private var browserZoomLevel = 1.0
    @AppStorage("hlsSniffingEnabled") private var hlsSniffingEnabled = true
    @AppStorage("videoSniffingEnabled") private var videoSniffingEnabled = true
    @AppStorage("adRedirectBlockingEnabled") private var adRedirectBlockingEnabled = false
    @AppStorage("popupBlockingEnabled") private var popupBlockingEnabled = false
    @AppStorage("customAdDomains") private var customAdDomains = ""
    @AppStorage("subscribedAdDomains") private var subscribedAdDomains = ""
    @AppStorage("subscribedAdCosmeticRules") private var subscribedAdCosmeticRules = ""
    @AppStorage("adRulesAutoUpdate") private var adRulesAutoUpdate = "never"
    @AppStorage("adRulesLastUpdatedAt") private var adRulesLastUpdatedAt = 0.0
    @AppStorage("adRulesSkippedCount") private var adRulesSkippedCount = 0
    @State private var isRefreshingAdRules = false
    @State private var adRulesStatus = "尚未更新订阅规则"
    @AppStorage("defaultSearchEngine") private var defaultSearchEngine = "bing"
    @AppStorage("browserHomePage") private var browserHomePage = "start"
    @AppStorage("browserCustomHomeURL") private var browserCustomHomeURL = ""
    @AppStorage("browserMenuDownloadOrder") private var browserMenuDownloadOrder = "downloads,files"
    @AppStorage("browserMenuBrowserOrder") private var browserMenuBrowserOrder = "history,bookmarks,sniff,share"
    @AppStorage("browserMenuDisplayOrder") private var browserMenuDisplayOrder = "desktop,strip,zoom"
    @AppStorage("browserMenuActionOrder") private var browserMenuActionOrder = "refresh,copy,settings"
    @AppStorage("alistBaseURL") private var alistBaseURL = ""
    @AppStorage("alistUsername") private var alistUsername = ""
    @AppStorage("alistTargetDirectory") private var alistTargetDirectory = "/"
    @AppStorage("alistChooseDirectoryOnUpload") private var alistChooseDirectoryOnUpload = false
    @State private var showingAListDirectoryPicker = false
    @State private var alistDirectoryPath = "/"
    @State private var alistDirectories: [AListDirectory] = []
    @State private var isLoadingAListDirectories = false
    @State private var pendingAListUploadURL: URL?
    @State private var menuEditMode: EditMode = .inactive
    @State private var showingBrowserCandidates = false
    @State private var showingBrowsingHistory = false
    @State private var showingBookmarks = false

    // Browser
    @State private var browserAddress = ""
    @State private var candidates: [URL] = []
    @State private var candidateCookies: [String: [HTTPCookie]] = [:]
    @State private var candidateMetadata: [String: String] = [:]
    @State private var candidateSizes: [String: Int64] = [:]

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
    @State private var alistPassword = ""
    @State private var alistOTPCode = ""
    @State private var alistSettingsStatus = "尚未测试连接"
    @State private var isTestingAList = false
    @State private var uploadedFileURLs = Set<String>()

    // Local files
    @State private var localFiles: [URL] = []
    @State private var playingURL: URL?

    var body: some View {
        browserTab
        .tint(.blue)
        .onAppear {
            refreshFiles()
            if alistPassword.isEmpty { alistPassword = AListCredentialStore.loadPassword() ?? "" }
            checkAdRulesAutoUpdate()
            downloadQueue.onCompleted = { url, sourceURL in
                library.recordDownload(fileURL: url, sourceURL: sourceURL)
                refreshFiles()
            }
            browserAddress = tabManager.activeTab.url
            AppDiagnostics.shared.log("APP", "ContentView appeared")
        }
        .onChange(of: tabManager.activeTabID) { _ in
            browserAddress = tabManager.activeTab.url
        }
        .onChange(of: scenePhase) { phase in
            AppDiagnostics.shared.log("APP", "scenePhase=\(String(describing: phase))")
            if phase == .active { downloadQueue.applicationDidBecomeActive() }
        }
        .sheet(isPresented: $showingVariants) {
            variantPicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: Binding(
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
                    TextField("搜索或输入网址", text: Binding(
                        get: { addressBarDisplayValue },
                        set: { browserAddress = $0 }
                    ))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(loadBrowserAddress)
                    if browserController.isLoading {
                        Button { browserController.stopLoading() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    } else {
                        Button { browserController.reload() } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                        }.disabled(currentPageURL == nil)
                    }
                    Button(action: toggleCurrentBookmark) {
                        Image(systemName: currentPageIsBookmarked ? "bookmark.fill" : "bookmark")
                    }.disabled(currentPageURL == nil)
                }
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().stroke(Color(uiColor: .separator).opacity(0.2)))
                .padding(.horizontal, 14).padding(.vertical, 8)

                if browserController.showsNavigationProgress {
                    ProgressView(value: browserController.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .frame(height: 2)
                        .padding(.horizontal, 14)
                        .padding(.top, -5)
                        .padding(.bottom, 3)
                }

                ZStack {
                    BrowserView(
                        address: browserAddress,
                        controller: browserController,
                        onCapture: addCandidate,
                        onAddressChange: { value in
                            browserAddress = value
                            let title = browserController.webView?.title ?? URL(string: value)?.host ?? value
                            tabManager.update(tabManager.activeTabID, url: value, title: title)
                            if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                library.recordVisit(url: url, title: title)
                            }
                        },
                        onNewTab: { url in
                            tabManager.addTab(url: url)
                            browserAddress = url?.absoluteString ?? ""
                            showingTabOverview = false
                        },
                        isSniffingEnabled: hlsSniffingEnabled,
                        isVideoSniffingEnabled: videoSniffingEnabled,
                        isAdRedirectBlockingEnabled: adRedirectBlockingEnabled,
                        isPopupBlockingEnabled: popupBlockingEnabled,
                        customAdDomains: customAdDomains + "\n" + subscribedAdDomains + "\n" + subscribedAdCosmeticRules,
                        isDesktopMode: browserDesktopMode,
                        stripMobilePrefix: browserStripMobilePrefix,
                        zoomLevel: browserZoomLevel
                    )
                    .id(tabManager.activeTabID.uuidString + browserController.webViewID.uuidString)

                    if browserController.isShowingStartPage {
                        VStack(spacing: 22) {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "safari").font(.system(size: 44, weight: .light)).foregroundStyle(.blue)
                                Text("轻装上网").font(.title3.weight(.semibold))
                                Text("搜索，或输入网址开始浏览").font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 14) {
                                HStack(spacing: 14) {
                                    browserShortcut("百度", icon: "magnifyingglass", url: "https://www.baidu.com")
                                    browserShortcut("必应", icon: "sparkle.magnifyingglass", url: "https://www.bing.com")
                                    browserShortcut("GitHub", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com")
                                    browserShortcut("YouTube", icon: "play.rectangle", url: "https://www.youtube.com")
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .background(Color(uiColor: .systemBackground))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 0) {
                    browserTool("chevron.left", disabled: !browserController.canGoBack) { browserController.goBack() }
                    browserTool("chevron.right", disabled: !browserController.canGoForward) { browserController.goForward() }
                    browserTool("house") { openHomePage() }
                    Button { captureTabPreviews(); showingTabOverview = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 19, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 48)
                            Text("\(tabManager.tabs.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(.blue, in: Capsule())
                                .offset(x: -8, y: 5)
                        }
                    }
                    .buttonStyle(.plain)
                    Button { showingBrowserMenu = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 19, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 48)
                            if !candidates.isEmpty {
                                Circle().fill(.blue).frame(width: 7, height: 7).offset(x: -12, y: 9)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(uiColor: .separator).opacity(0.2)).frame(height: 0.5)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarHidden(true)
            .sheet(isPresented: $showingBrowserCandidates) { browserCandidatesSheet }
            .sheet(isPresented: $showingBrowsingHistory) { browsingHistorySheet }
            .sheet(isPresented: $showingBookmarks) { browserBookmarksSheet }
            .sheet(isPresented: $showingDownloads) { downloadsTab }
            .sheet(isPresented: $showingFiles) { filesTab }
            .sheet(isPresented: $showingAListDirectoryPicker) { alistDirectoryPicker }
            .sheet(isPresented: $showingBrowserMenu) {
                browserMenuSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingTabOverview) {
                tabOverviewSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var browserCandidatesSheet: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                        Text("暂未发现视频").font(.headline)
                        Text("播放网页中的视频后，识别到的资源会显示在这里。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ForEach(sortedCandidates, id: \.absoluteString) { url in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "film").foregroundStyle(.blue)
                                Text(url.lastPathComponent.isEmpty ? "视频流" : url.lastPathComponent)
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if url.pathExtension.lowercased() == "m3u8" {
                                    Button("解析") {
                                        AppDiagnostics.shared.log("UI", "点击解析 HLS 候选 url=\(AppDiagnostics.safeURL(url))")
                                        let cookies = candidateCookies[candidateKey(url)] ?? []
                                        showingBrowserCandidates = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            inspect(url, cookies: cookies)
                                        }
                                    }.buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                            Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(candidateMetadata[candidateKey(url)] ?? "正在识别…")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button {
                                    AppDiagnostics.shared.log("UI", "点击复制嗅探地址")
                                    UIPasteboard.general.string = url.absoluteString
                                } label: {
                                    Label("复制地址", systemImage: "doc.on.doc")
                                }.buttonStyle(.bordered).controlSize(.small)
                                if (candidateMetadata[candidateKey(url)] ?? "").hasPrefix("普通视频直链") {
                                    Button {
                                        AppDiagnostics.shared.log("UI", "点击下载普通视频 url=\(AppDiagnostics.safeURL(url))")
                                        showingBrowserCandidates = false
                                        startDirectVideoDownload(url, cookies: candidateCookies[candidateKey(url)] ?? [])
                                    } label: { Label("下载", systemImage: "arrow.down.circle") }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }.font(.caption)
                        }.padding(.vertical, 5)
                    }
                }
            }
            .navigationTitle("视频嗅探")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { showingBrowserCandidates = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        candidates.removeAll()
                        candidateCookies.removeAll()
                        candidateMetadata.removeAll()
                        candidateSizes.removeAll()
                    }.disabled(candidates.isEmpty)
                }
            }
        }
    }

    private var browserMenuSheet: some View {
        NavigationStack {
            List {
                Section("下载器") {
                    ForEach(orderedMenuItems(browserMenuDownloadOrder, defaults: ["downloads", "files"]), id: \.self) { item in
                        browserMenuRow(item)
                    }
                    .onMove { source, destination in
                        moveMenuItems(source, to: destination, raw: browserMenuDownloadOrder, defaults: ["downloads", "files"]) {
                            browserMenuDownloadOrder = $0
                        }
                    }
                }
                Section("浏览器") {
                    ForEach(orderedMenuItems(browserMenuBrowserOrder, defaults: ["history", "bookmarks", "sniff", "share"]), id: \.self) { item in
                        browserMenuRow(item)
                    }
                    .onMove { source, destination in
                        moveMenuItems(source, to: destination, raw: browserMenuBrowserOrder, defaults: ["history", "bookmarks", "sniff", "share"]) {
                            browserMenuBrowserOrder = $0
                        }
                    }
                }
                Section("网页显示") {
                    ForEach(orderedMenuItems(browserMenuDisplayOrder, defaults: ["desktop", "strip", "zoom"]), id: \.self) { item in
                        browserMenuRow(item)
                    }
                    .onMove { source, destination in
                        moveMenuItems(source, to: destination, raw: browserMenuDisplayOrder, defaults: ["desktop", "strip", "zoom"]) {
                            browserMenuDisplayOrder = $0
                        }
                    }
                }
                Section("页面操作") {
                    ForEach(orderedMenuItems(browserMenuActionOrder, defaults: ["refresh", "copy", "settings"]), id: \.self) { item in
                        browserMenuRow(item)
                    }
                    .onMove { source, destination in
                        moveMenuItems(source, to: destination, raw: browserMenuActionOrder, defaults: ["refresh", "copy", "settings"]) {
                            browserMenuActionOrder = $0
                        }
                    }
                }
            }
            .environment(\.editMode, $menuEditMode)
            .listStyle(.insetGrouped)
            .navigationTitle("浏览器菜单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(menuEditMode == .active ? "完成排序" : "开始排序") {
                        menuEditMode = menuEditMode == .active ? .inactive : .active
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingBrowserMenu = false; menuEditMode = .inactive }
                }
            }
        }
    }

    @ViewBuilder
    private func browserMenuRow(_ item: String) -> some View {
        switch item {
        case "downloads":
            NavigationLink { downloadsTab } label: { Label("下载管理 · 解析与下载任务", systemImage: "arrow.down.circle.fill") }
        case "files":
            NavigationLink { filesTab } label: { Label("已下载文件", systemImage: "folder") }
        case "history":
            menuAction("历史记录", icon: "clock.arrow.circlepath") { showingBrowserMenu = false; showingBrowsingHistory = true }
        case "bookmarks":
            menuAction("书签", icon: "bookmark") { showingBrowserMenu = false; showingBookmarks = true }
        case "sniff":
            menuAction("视频嗅探（\(candidates.count)）", icon: "dot.radiowaves.left.and.right") { showingBrowserMenu = false; showingBrowserCandidates = true }
        case "share":
            menuAction("分享网页", icon: "square.and.arrow.up") {
                if let url = currentPageURL { UIPasteboard.general.string = url.absoluteString }
                showingBrowserMenu = false
            }
        case "desktop":
            Toggle("桌面版网站", isOn: $browserDesktopMode)
        case "strip":
            Toggle("桌面版时去除 m. 前缀", isOn: $browserStripMobilePrefix)
                .disabled(!browserDesktopMode)
        case "zoom":
            HStack {
                Text("网页缩放")
                Spacer()
                Button { browserZoomLevel = max(0.5, browserZoomLevel - 0.1); applyBrowserZoom() } label: { Image(systemName: "minus.circle") }
                Text("\(Int(browserZoomLevel * 100))%").monospacedDigit().frame(minWidth: 48)
                Button { browserZoomLevel = min(2.0, browserZoomLevel + 0.1); applyBrowserZoom() } label: { Image(systemName: "plus.circle") }
                Button("重置") { browserZoomLevel = 1; applyBrowserZoom() }.font(.caption)
            }
        case "refresh":
            menuAction("刷新网页", icon: "arrow.clockwise") { browserController.reload(); showingBrowserMenu = false }
        case "copy":
            menuAction("复制当前网址", icon: "doc.on.doc") {
                if let url = currentPageURL { UIPasteboard.general.string = url.absoluteString }
                showingBrowserMenu = false
            }
        case "settings":
            NavigationLink { settingsTab } label: { Label("设置", systemImage: "gearshape") }
        default:
            EmptyView()
        }
    }

    private func orderedMenuItems(_ raw: String, defaults: [String]) -> [String] {
        let saved = raw.split(separator: ",").map(String.init)
        return saved.filter { defaults.contains($0) } + defaults.filter { !saved.contains($0) }
    }

    private func moveMenuItems(_ source: IndexSet, to destination: Int, raw: String, defaults: [String], save: (String) -> Void) {
        var items = orderedMenuItems(raw, defaults: defaults)
        items.move(fromOffsets: source, toOffset: destination)
        save(items.joined(separator: ","))
    }

    private var tabOverviewSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(tabManager.tabs) { tab in
                        VStack(alignment: .leading, spacing: 9) {
                            ZStack(alignment: .topTrailing) {
                                if let preview = tabPreviews[tab.id] {
                                    Image(uiImage: preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 112)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                        .frame(height: 112)
                                        .overlay {
                                            VStack(spacing: 7) {
                                                Image(systemName: "safari").font(.system(size: 28)).foregroundStyle(.secondary)
                                                Text(tab.url.isEmpty ? "起始页" : (URL(string: tab.url)?.host ?? tab.url))
                                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }.padding(.horizontal, 8)
                                        }
                                }
                                Button {
                                    tabManager.close(tab.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .gray)
                                }.padding(7)
                            }
                            Text(tab.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(tab.url.isEmpty ? "新标签页" : tab.url)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(9)
                        .background(tab.id == tabManager.activeTabID ? Color.blue.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tab.id == tabManager.activeTabID ? Color.blue.opacity(0.5) : .clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            tabManager.activate(tab.id)
                            browserAddress = tab.url
                            showingTabOverview = false
                        }
                        .contextMenu {
                            Button("关闭标签页", role: .destructive) { tabManager.close(tab.id) }
                            Button("关闭其他标签页") { tabManager.closeOthers(keeping: tab.id) }
                        }
                        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                            if abs(value.translation.width) > 80 { tabManager.close(tab.id) }
                        })
                    }
                    Button {
                        tabManager.addTab()
                        browserAddress = ""
                        showingTabOverview = false
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 28, weight: .medium))
                            Text("新建标签页").font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 158)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }.padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("标签页（\(tabManager.tabs.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingTabOverview = false } } }
        }
    }

    private func captureTabPreviews() {
        for tab in tabManager.tabs {
            guard let webView = tab.controller.webView else { continue }
            webView.takeSnapshot(with: nil) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async { tabPreviews[tab.id] = image }
            }
        }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                Section("管理") {
                    NavigationLink { downloadsTab } label: { Label("下载管理", systemImage: "arrow.down.circle") }
                    NavigationLink { filesTab } label: { Label("文件管理", systemImage: "folder") }
                }
                Section("设置") {
                    NavigationLink { settingsTab } label: { Label("设置", systemImage: "gearshape") }
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("浏览器内核", value: "WKWebView")
                }
            }
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func menuAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            AppDiagnostics.shared.log("UI", "点击菜单：\(title)")
            action()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applyBrowserZoom() {
        let script = "document.documentElement.style.zoom = '\(browserZoomLevel)'"
        browserController.webView?.evaluateJavaScript(script, completionHandler: nil)
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
        Button {
            AppDiagnostics.shared.log("UI", "点击底部浏览器按钮：\(symbol)")
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .foregroundStyle(disabled ? .tertiary : .primary)
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func browserLibraryTool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text("添加下载").font(.title2.bold())
                        Text("粘贴 M3U8 地址解析清晰度，也可以从网页嗅探结果直接加入队列。")
                            .font(.subheadline).foregroundStyle(.secondary)
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
                                if let value = UIPasteboard.general.string { directURL = value }
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.title3).frame(width: 42, height: 46)
                            }.buttonStyle(.bordered)
                        }
                        Button(action: parseDirectURL) {
                            if isInspecting { ProgressView().frame(maxWidth: .infinity) }
                            else { Label("解析 M3U8 地址", systemImage: "text.magnifyingglass").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInspecting)
                    }
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(uiColor: .separator).opacity(0.25)))

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("下载队列").font(.title3.bold())
                            Text("最多同时下载 3 个任务，其余自动排队")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(downloadQueue.activeCount) 进行中 · \(downloadQueue.queuedCount) 排队")
                            .font(.caption.weight(.medium)).foregroundStyle(.blue)
                    }

                    if downloadQueue.items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 38)).foregroundStyle(.tertiary)
                            Text("队列为空").font(.headline)
                            Text("从网页嗅探视频，或粘贴 M3U8 地址开始下载。")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(downloadQueue.items) { item in
                                DownloadQueueRow(
                                    item: item,
                                    onPause: { downloadQueue.pause(item) },
                                    onResume: { downloadQueue.resume(item) },
                                    onCancel: { downloadQueue.cancel(item) },
                                    onRetry: { downloadQueue.retry(item) },
                                    onRemove: { downloadQueue.remove(item) }
                                )
                                if item.id != downloadQueue.items.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        Button("清理已完成 / 失败 / 已取消记录") {
                            downloadQueue.clearFinished()
                        }
                        .font(.caption)
                        .disabled(!downloadQueue.items.contains { [.completed, .failed, .cancelled].contains($0.state) })
                    }

                    if !library.history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("下载历史").font(.title3.bold())
                                Spacer()
                                Button("清空") {
                                    let oldEntries = library.history
                                    for entry in oldEntries { library.removeHistory(entry.id) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(library.history.prefix(30))) { entry in
                                    HStack(spacing: 10) {
                                        Image(systemName: "film").foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text(entry.completedAt.formatted(date: .numeric, time: .shortened))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let url = URL(string: entry.fileURL), FileManager.default.fileExists(atPath: url.path) {
                                            Button { openPlayer(url) } label: { Image(systemName: "play.circle").font(.title3) }
                                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                        }
                                        Button(role: .destructive) { library.removeHistory(entry.id) } label: {
                                            Image(systemName: "trash")
                                        }.buttonStyle(.plain)
                                    }.padding(.vertical, 8)
                                    if entry.id != library.history.prefix(30).last?.id { Divider() }
                                }
                            }
                            .padding(.horizontal, 12)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    Label("最多 3 个任务并行；HLS 暂停后保留已下载分片，继续时从缓存恢复。切到后台会申请有限执行时间，时间耗尽后自动暂停，回到应用可继续。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("下载管理")
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
                                    if alistUploader.currentFilePath == url.path {
                                        ProgressView(value: alistUploader.progress)
                                        Text(alistUploader.status)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else if uploadedFileURLs.contains(url.absoluteString) {
                                        Label("已上传到 AList", systemImage: "checkmark.circle.fill")
                                            .font(.caption2).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Button {
                                    uploadToAList(url)
                                } label: {
                                    Image(systemName: alistUploader.currentFilePath == url.path ? "arrow.up.circle.fill" : "arrow.up.to.line")
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                                .disabled(alistUploader.isUploading)
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
                    Label("网页视频使用网站自己的播放器", systemImage: "play.rectangle")
                        .font(.subheadline)
                    Text("已启用 WKWebView 内联播放和 playsinline 兼容处理。嗅探只记录候选地址，不会拦截网页播放器或自动接管播放；需要下载时仍可从视频嗅探页单独操作。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(hlsSniffingEnabled ? "已开启：浏览网页时自动检测 HLS 视频地址。" : "已关闭：不注入 HLS 嗅探脚本，普通网页仍可正常浏览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("广告域名拦截", isOn: $adRedirectBlockingEnabled)
                    Text("开启后拦截内置、自定义及订阅域名的网页请求和顶层跳转。默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("弹窗 / 新窗口拦截", isOn: $popupBlockingEnabled)
                    Text("阻止网页通过 window.open 或新窗口链接打开页面。默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("主页") {
                    Picker("主页内容", selection: $browserHomePage) {
                        Text("起始页").tag("start")
                        Text("自定义网址").tag("custom")
                    }
                    if browserHomePage == "custom" {
                        TextField("https://example.com", text: $browserCustomHomeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Text("点击浏览器底部的主页按钮时打开此页面。起始页仅提供搜索和常用网站快捷入口。")
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
                Section("ABP 自定义规则") {
                    Text("支持常用 Adblock Plus 规则：||example.com^ 拦截域名请求；@@||example.com^ 例外规则暂不转换；example.com##.ad 隐藏网页元素。复杂正则和高级选项会按兼容能力处理。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $customAdDomains)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("每行一条规则")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清空自定义规则", role: .destructive) { customAdDomains = "" }
                            .font(.caption)
                    }
                }
                Section("广告规则订阅") {
                    Picker("自动更新", selection: $adRulesAutoUpdate) {
                        Text("从不").tag("never")
                        Text("每天").tag("daily")
                        Text("每周").tag("weekly")
                    }
                    Text("订阅 EasyList、EasyList China、CJX's Annoyance、EasyPrivacy、EasyList Warning Removal 和老毛子规则。域名请求规则分批编译，网页元素隐藏规则单独注入；并非所有 ABP 高级语法都能由 WebKit 完整支持。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscribedAdDomains.isEmpty && subscribedAdCosmeticRules.isEmpty ? "未下载订阅规则" : "\(subscribedAdDomains.components(separatedBy: .newlines).filter { !$0.isEmpty }.count) 个域名 · \(subscribedAdCosmeticRules.components(separatedBy: .newlines).filter { !$0.isEmpty }.count) 条元素规则")
                                .font(.subheadline.weight(.medium))
                            Text(adRulesStatus + " · 未转换规则：\(adRulesSkippedCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            refreshAdRules()
                        } label: {
                            if isRefreshingAdRules { ProgressView() }
                            else { Label("更新全部", systemImage: "arrow.clockwise") }
                        }.disabled(isRefreshingAdRules)
                    }
                    if !subscribedAdDomains.isEmpty || !subscribedAdCosmeticRules.isEmpty {
                        Button("清除订阅规则", role: .destructive) {
                            subscribedAdDomains = ""
                            subscribedAdCosmeticRules = ""
                            adRulesStatus = "已清除订阅规则"
                        }
                    }
                }
                Section("AList 上传") {
                    TextField("AList 地址，例如 https://alist.example.com", text: $alistBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("AList 用户名", text: $alistUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("AList 密码", text: $alistPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("二步验证码（如启用）", text: $alistOTPCode)
                        .keyboardType(.numberPad)
                    Toggle("上传时选择目录", isOn: $alistChooseDirectoryOnUpload)
                    HStack {
                        Text("默认上传目录")
                        Spacer()
                        Text(alistTargetDirectory.isEmpty ? "/" : alistTargetDirectory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("关闭时直接上传到记住的目录；开启后每次上传前可浏览并选择 AList 文件夹，选择结果会自动记住。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            testAListConnection()
                        } label: {
                            if isTestingAList { ProgressView() }
                            else { Label("测试连接并保存", systemImage: "checkmark.icloud") }
                        }
                        .disabled(isTestingAList || alistBaseURL.isEmpty || alistUsername.isEmpty || alistPassword.isEmpty)
                        Spacer()
                        Button("清除密码", role: .destructive) {
                            AListCredentialStore.deletePassword()
                            alistPassword = ""
                            alistSettingsStatus = "已清除本机保存的密码"
                        }
                        .font(.caption)
                    }
                    Text(alistSettingsStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("上传使用 AList 原生 PUT /api/fs/put 接口。账号密码仅保存在本机钥匙串；上传时重新登录获取临时 Token。目标目录需事先存在并具有写入权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("下载通知") {
                    Button {
                        downloadQueue.requestNotificationPermission()
                    } label: {
                        Label("允许下载完成通知", systemImage: "bell.badge")
                    }
                    Text("授权后，下载完成时会发送本地通知。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    .disabled(!parsedIsEndList && variants.isEmpty)
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
        AppDiagnostics.shared.log("SNIFF", "候选进入列表回调 url=\(AppDiagnostics.safeURL(url)) direct=\(isDirectVideoResponse)")
        let key = candidateKey(url)
        candidateCookies[key] = cookies
        guard !candidates.contains(where: { candidateKey($0) == key }) else { return }
        candidates.insert(url, at: 0)
        let ext = url.pathExtension.lowercased()
        let isDirectVideo = isDirectVideoResponse || ["mp4", "m4v", "mov", "webm", "mkv", "avi"].contains(ext)
        candidateMetadata[key] = isDirectVideo ? "普通视频直链 · 正在获取大小…" : "正在识别播放列表…"
        if candidates.count > 20 {
            let removed = candidates.suffix(from: 20)
            for item in removed {
                let removedKey = candidateKey(item)
                candidateCookies.removeValue(forKey: removedKey)
                candidateMetadata.removeValue(forKey: removedKey)
                candidateSizes.removeValue(forKey: removedKey)
            }
            candidates = Array(candidates.prefix(20))
        }

        guard !isDirectVideo else {
            Task {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 10
                if let page = currentPageURL { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
                if let host = url.host?.lowercased() {
                    let matching = cookies.filter { cookie in
                        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path)
                    }
                    for (name, value) in HTTPCookie.requestHeaderFields(with: matching) {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                }
                var bytes: Int64 = -1
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    bytes = response.expectedContentLength
                    if let http = response as? HTTPURLResponse,
                       let raw = http.value(forHTTPHeaderField: "Content-Length"),
                       let value = Int64(raw), value > 0 { bytes = value }
                } catch {}
                await MainActor.run {
                    guard candidates.contains(where: { candidateKey($0) == key }) else { return }
                    if bytes > 0 {
                        candidateSizes[key] = bytes
                        let formatter = ByteCountFormatter()
                        formatter.countStyle = .file
                        candidateMetadata[key] = "普通视频直链 · " + formatter.string(fromByteCount: bytes)
                    } else {
                        candidateMetadata[key] = "普通视频直链 · 大小未知"
                    }
                }
            }
            return
        }

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

    private var sortedCandidates: [URL] {
        candidates.sorted { left, right in
            let leftSize = candidateSizes[candidateKey(left)] ?? -1
            let rightSize = candidateSizes[candidateKey(right)] ?? -1
            if leftSize != rightSize { return leftSize > rightSize }
            return left.absoluteString < right.absoluteString
        }
    }

    private var addressBarDisplayValue: String {
        if browserAddress.hasPrefix("https://") { return String(browserAddress.dropFirst(8)) }
        if browserAddress.hasPrefix("http://") { return String(browserAddress.dropFirst(7)) }
        return browserAddress
    }

    private var currentPageURL: URL? {
        let url = browserController.webView?.url ?? URL(string: browserAddress)
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private var currentPageIsBookmarked: Bool {
        guard let url = currentPageURL else { return false }
        return library.isBookmarked(url)
    }

    private func toggleCurrentBookmark() {
        guard let url = currentPageURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let existing = library.bookmarks.first(where: { $0.url == url.absoluteString }) {
            library.removeBookmark(existing.id)
        } else {
            let title = browserController.webView?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (title?.isEmpty == false ? title! : (url.host ?? url.absoluteString))
            library.addBookmark(url: url, title: value)
        }
    }

    private func openPlayer(_ url: URL) {
        guard playingURL == nil else { return }
        AppDiagnostics.shared.log("PLAYER", "请求打开本地视频 file=\(url.lastPathComponent)")
        playingURL = url
    }

    private func startDirectVideoDownload(_ url: URL, cookies: [HTTPCookie]) {
        downloadQueue.enqueueDirect(url, cookies: cookies, referrer: currentPageURL)
        showingDownloads = true
    }

    private var alistDirectoryPicker: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(alistDirectoryPath)
                            .font(.subheadline)
                            .lineLimit(2)
                        Spacer()
                        Button("选择此目录") { confirmAListDirectorySelection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoadingAListDirectories)
                    }
                }
                if alistDirectoryPath != "/" {
                    Button {
                        let parts = alistDirectoryPath.split(separator: "/")
                        alistDirectoryPath = parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
                        loadAListDirectories()
                    } label: {
                        Label("返回上一级", systemImage: "arrow.up.left")
                    }
                }
                Section("文件夹") {
                    if isLoadingAListDirectories {
                        HStack { Spacer(); ProgressView("正在读取目录…"); Spacer() }
                    } else if alistDirectories.isEmpty {
                        Text("此目录下没有子文件夹").foregroundStyle(.secondary)
                    } else {
                        ForEach(alistDirectories) { directory in
                            Button {
                                alistDirectoryPath = alistDirectoryPath == "/" ? "/\(directory.name)" : alistDirectoryPath + "/\(directory.name)"
                                loadAListDirectories()
                            } label: {
                                Label(directory.name, systemImage: "folder")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择 AList 上传目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showingAListDirectoryPicker = false; pendingAListUploadURL = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { loadAListDirectories() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isLoadingAListDirectories)
                }
            }
            .task { loadAListDirectories() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func loadAListDirectories() {
        let password = alistPassword.isEmpty ? (AListCredentialStore.loadPassword() ?? "") : alistPassword
        guard !alistBaseURL.isEmpty, !alistUsername.isEmpty, !password.isEmpty else {
            errorMessage = "请先在设置中配置并测试 AList 登录。"
            showingAListDirectoryPicker = false
            return
        }
        isLoadingAListDirectories = true
        Task {
            do {
                let result = try await alistUploader.listDirectories(
                    serverAddress: alistBaseURL,
                    username: alistUsername,
                    password: password,
                    otpCode: alistOTPCode,
                    directory: alistDirectoryPath
                )
                alistDirectories = result
            } catch {
                errorMessage = "读取 AList 目录失败：\\(error.localizedDescription)"
            }
            isLoadingAListDirectories = false
        }
    }

    private func confirmAListDirectorySelection() {
        alistTargetDirectory = alistDirectoryPath
        showingAListDirectoryPicker = false
        guard let fileURL = pendingAListUploadURL else { return }
        pendingAListUploadURL = nil
        performAListUpload(fileURL)
    }

    private func testAListConnection() {
        isTestingAList = true
        alistSettingsStatus = "正在连接 AList…"
        Task {
            do {
                try await alistUploader.testConnection(
                    serverAddress: alistBaseURL,
                    username: alistUsername,
                    password: alistPassword,
                    otpCode: alistOTPCode
                )
                try AListCredentialStore.save(password: alistPassword)
                alistSettingsStatus = "连接成功，账号密码已安全保存"
            } catch {
                alistSettingsStatus = "连接失败：\(error.localizedDescription)"
            }
            isTestingAList = false
        }
    }

    private func uploadToAList(_ fileURL: URL) {
        let password = alistPassword.isEmpty ? (AListCredentialStore.loadPassword() ?? "") : alistPassword
        guard !alistBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !alistUsername.isEmpty, !password.isEmpty else {
            errorMessage = "请先到设置 → AList 上传，填写服务器地址、账号和密码并测试连接。"
            return
        }
        Task {
            do {
                try await alistUploader.upload(
                    fileURL: fileURL,
                    serverAddress: alistBaseURL,
                    username: alistUsername,
                    password: password,
                    otpCode: alistOTPCode,
                    targetDirectory: alistTargetDirectory
                )
                uploadedFileURLs.insert(fileURL.absoluteString)
            } catch {
                errorMessage = "AList 上传失败：\(error.localizedDescription)"
            }
        }
    }

    private func formattedFileDate(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func openHomePage() {
        AppDiagnostics.shared.log("UI", "主页按钮执行，主页类型=\(browserHomePage)")
        if browserHomePage == "custom" {
            let raw = browserCustomHomeURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                browserAddress = ""
                tabManager.update(tabManager.activeTabID, url: "", title: "起始页")
                browserController.showStartPage()
                return
            }
            let normalized = raw.contains("://") ? raw : "https://" + raw
            guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                errorMessage = "主页网址无效，请在设置中检查。"
                return
            }
            browserAddress = url.absoluteString
            tabManager.update(tabManager.activeTabID, url: url.absoluteString, title: url.host ?? "主页")
            browserController.load(url)
        } else {
            browserAddress = ""
            tabManager.update(tabManager.activeTabID, url: "", title: "起始页")
            browserController.showStartPage()
        }
    }

    private func loadBrowserAddress() {
        let raw = browserAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let hasWhitespace = raw.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let normalized = raw.contains("://") ? raw : "https://" + raw
        if !hasWhitespace, let url = URL(string: normalized),
           let host = url.host, host.contains("."), !host.hasPrefix(".") {
            var targetURL = url
            if browserDesktopMode && browserStripMobilePrefix,
               let host = url.host, host.lowercased().hasPrefix("m."),
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.host = String(host.dropFirst(2))
                if let stripped = components.url { targetURL = stripped }
            }
            browserAddress = targetURL.absoluteString
            browserController.load(targetURL)
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

    private func checkAdRulesAutoUpdate() {
        let interval: TimeInterval
        switch adRulesAutoUpdate {
        case "daily": interval = 24 * 60 * 60
        case "weekly": interval = 7 * 24 * 60 * 60
        default: return
        }
        guard Date().timeIntervalSince1970 - adRulesLastUpdatedAt >= interval else { return }
        refreshAdRules()
    }

    private func refreshAdRules() {
        isRefreshingAdRules = true
        adRulesStatus = "正在更新 6 个规则订阅…"
        Task {
            let feeds: [(String, String)] = [
                ("EasyList", "https://easylist.to/easylist/easylist.txt"),
                ("EasyList China", "https://easylist-downloads.adblockplus.org/easylistchina.txt"),
                ("CJX's Annoyance", "https://raw.githubusercontent.com/cjx82630/cjxlist/master/cjx-annoyance.txt"),
                ("EasyList Privacy", "https://easylist-downloads.adblockplus.org/easyprivacy.txt"),
                ("EasyList Warning Removal", "https://easylist-msie.adblockplus.org/antiadblockfilters.txt"),
                ("老毛子", "https://easylist-downloads.adblockplus.org/ruadlist+easylist.txt")
            ]
            var domains = Set<String>()
            var cosmetic = Set<String>()
            var succeeded = 0
            var failures: [String] = []
            var skipped = 0
            for (name, address) in feeds {
                do {
                    guard let url = URL(string: address) else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 45
                    request.setValue("text/plain", forHTTPHeaderField: "Accept")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let text = String(data: data, encoding: .utf8) else {
                        throw URLError(.badServerResponse)
                    }
                    succeeded += 1
                    for rawLine in text.components(separatedBy: .newlines) {
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                        if line.hasPrefix("@@") { skipped += 1; continue }
                        if line.contains("##"), !line.contains("#@#"), !line.hasPrefix("##") {
                            cosmetic.insert(line)
                            continue
                        }
                        let normalized = line.lowercased()
                        if normalized.hasPrefix("||") {
                            let body = String(normalized.dropFirst(2))
                            let host = String(body.prefix { $0 != "^" && $0 != "/" && $0 != "$" && $0 != "*" && $0 != "|" })
                            if Self.isValidAdDomain(host) { domains.insert(host) } else { skipped += 1 }
                        } else {
                            let fields = normalized.split(whereSeparator: { $0.isWhitespace })
                            if fields.count >= 2 && (fields[0] == "0.0.0.0" || fields[0] == "127.0.0.1") {
                                var accepted = 0
                                for field in fields.dropFirst() {
                                    let host = String(field)
                                    if Self.isValidAdDomain(host) { domains.insert(host); accepted += 1 }
                                }
                                if accepted == 0 { skipped += 1 }
                            } else {
                                skipped += 1
                            }
                        }
                    }
                } catch {
                    failures.append(name)
                }
            }
            await MainActor.run {
                guard succeeded > 0, !domains.isEmpty || !cosmetic.isEmpty else {
                    adRulesStatus = "更新失败：所有订阅均不可用"
                    isRefreshingAdRules = false
                    return
                }
                if !failures.isEmpty {
                    domains.formUnion(subscribedAdDomains.components(separatedBy: .newlines).filter { !$0.isEmpty })
                    cosmetic.formUnion(subscribedAdCosmeticRules.components(separatedBy: .newlines).filter { !$0.isEmpty })
                }
                subscribedAdDomains = domains.sorted().joined(separator: "\n")
                subscribedAdCosmeticRules = cosmetic.sorted().joined(separator: "\n")
                adRulesSkippedCount = skipped
                adRulesLastUpdatedAt = Date().timeIntervalSince1970
                browserController.reload()
                let failedText = failures.isEmpty ? "" : "；失败：\(failures.joined(separator: "、"))（已保留旧规则）"
                adRulesStatus = "更新完成：\(succeeded)/6 个订阅 · \(domains.count) 域名 · \(cosmetic.count) 元素规则\(failedText)"
                isRefreshingAdRules = false
            }
        }
    }

    private static func isValidAdDomain(_ domain: String) -> Bool {
        guard domain.utf8.count <= 253, domain.contains(".") else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            label.utf8.count <= 63 &&
            label.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
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
        downloadQueue.enqueueHLS(url, cookies: cookies)
        showingDownloads = true
    }

    private func refreshFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        localFiles = urls.filter { ["mp4", "ts", "m4v", "mov", "webm", "mkv", "avi"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        // The file manager lists files; download history is recorded only by
        // completed queue tasks. Do not recreate a history row after the user removes it.
        library.reconcileDownloadHistory(existingFileURLs: Set(localFiles.map(\.absoluteString)))
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
