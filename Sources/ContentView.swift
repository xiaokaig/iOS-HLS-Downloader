import SwiftUI
import AVKit
import WebKit

struct ContentView: View {
    @StateObject private var downloader = HLSDownloadManager()
    @State private var selectedTab = 0

    // Browser
    @State private var browserAddress = "https://"
    @State private var candidates: [URL] = []
    @State private var candidateCookies: [String: [HTTPCookie]] = [:]

    // Direct download / quality picker
    @State private var directURL = ""
    @State private var pendingURL: URL?
    @State private var pendingCookies: [HTTPCookie] = []
    @State private var variants: [HLSVariant] = []
    @State private var showingVariants = false
    @State private var errorMessage: String?

    // Local files
    @State private var localFiles: [URL] = []
    @State private var playingURL: URL?

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
        .onAppear(perform: refreshFiles)
        .sheet(isPresented: $showingVariants) {
            variantPicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $playingURL) { url in
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
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
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("输入网址并前往", text: $browserAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(loadBrowserAddress)
                    Button(action: loadBrowserAddress) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                    }
                    .disabled(browserAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.top, 8)

                BrowserView(
                    address: browserAddress,
                    onCapture: addCandidate,
                    onAddressChange: { browserAddress = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("发现可下载视频", systemImage: "dot.radiowaves.left.and.right")
                                .font(.headline)
                            Spacer()
                            Text("\(candidates.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Button("清除") {
                                candidates.removeAll()
                                candidateCookies.removeAll()
                            }
                            .font(.caption)
                        }
                        ForEach(candidates.prefix(3), id: \.absoluteString) { url in
                            HStack(spacing: 10) {
                                Image(systemName: "film")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent.isEmpty ? "HLS 视频流" : url.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(url.host ?? url.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("查看") {
                                    inspect(url, cookies: candidateCookies[url.absoluteString] ?? [])
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        if candidates.count > 3 {
                            Text("还有 \(candidates.count - 3) 个视频地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .navigationTitle("浏览器")
            .navigationBarTitleDisplayMode(.inline)
        }
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
                            Label("解析并下载", systemImage: "arrow.down.to.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || downloader.isDownloading)
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
                            Image(systemName: downloader.isDownloading ? "arrow.down.doc.fill" : "doc")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 44, height: 44)
                                .background(Color.blue.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(downloader.status)
                                    .font(.headline)
                                if downloader.isDownloading {
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
                        if let output = downloader.outputURL {
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
                                    Text(fileSize(url))
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
            .navigationTitle("文件")
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
                    Label("TS 转 MP4（尽力尝试）", systemImage: "checkmark.circle")
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
                    Text("未发现多个清晰度，将直接下载原始播放列表。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(variants) { variant in
                        Button {
                            showingVariants = false
                            startDownload(variant.url, cookies: pendingCookies)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(variant.resolution ?? "清晰度未知")
                                        .font(.headline)
                                    Text(variant.bandwidth > 0 ? String(format: "%.2f Mbps", Double(variant.bandwidth) / 1_000_000) : "码率未知")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.blue)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("选择清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { showingVariants = false }
                }
            }
        }
    }

    private func loadBrowserAddress() {
        let raw = browserAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        browserAddress = raw.contains("://") ? raw : "https://" + raw
    }

    private func addCandidate(_ url: URL, cookies: [HTTPCookie]) {
        candidateCookies[url.absoluteString] = cookies
        guard !candidates.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
        candidates.insert(url, at: 0)
        if candidates.count > 20 { candidates.removeLast(candidates.count - 20) }
    }

    private func parseDirectURL() {
        let raw = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS M3U8 地址。"
            return
        }
        inspect(url, cookies: [])
    }

    private func inspect(_ url: URL, cookies: [HTTPCookie]) {
        pendingURL = url
        pendingCookies = cookies
        errorMessage = nil
        Task {
            do {
                let found = try await downloader.variants(for: url, cookies: cookies)
                await MainActor.run {
                    variants = found
                    if found.isEmpty {
                        startDownload(url, cookies: cookies)
                    } else {
                        showingVariants = true
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func startDownload(_ url: URL, cookies: [HTTPCookie]) {
        Task {
            do {
                _ = try await downloader.start(url: url, cookies: cookies)
                await MainActor.run { refreshFiles() }
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
        localFiles = urls.filter { ["mp4", "ts", "m4v", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: localFiles[index])
        }
        refreshFiles()
    }
}
