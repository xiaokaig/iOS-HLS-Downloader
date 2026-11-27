import SwiftUI
import WebKit

@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()

    @Published private(set) var recentText = ""
    private let fileURL: URL
    private let maxBytes = 2 * 1024 * 1024
    private let previewBytes = 20_000
    private var lastPreviewUpdate = Date.distantPast
    private var lastEventAt: [String: Date] = [:]
    private var suppressedCounts: [String: Int] = [:]
    private static let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("app-diagnostics.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        refresh()
        log("APP", "诊断日志启动")
    }

    func log(_ category: String, _ message: String, deduplicateFor interval: TimeInterval = 1.0) {
        let key = category + "|" + message
        let now = Date()
        if let previous = lastEventAt[key], now.timeIntervalSince(previous) < interval {
            suppressedCounts[key, default: 0] += 1
            return
        }

        let suppressed = suppressedCounts.removeValue(forKey: key) ?? 0
        lastEventAt[key] = now
        if lastEventAt.count > 500 {
            lastEventAt = lastEventAt.filter { now.timeIntervalSince($0.value) < 30 }
        }

        let suffix = suppressed > 0 ? "（相同事件合并 \(suppressed) 次）" : ""
        append("[\(Self.formatter.string(from: now))] [\(category)] \(message)\(suffix)\n")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()

            let size = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > maxBytes {
                var contents = (try? Data(contentsOf: fileURL)) ?? Data()
                let keepFrom = contents.count / 2
                if let newline = contents[keepFrom...].firstIndex(of: 10) {
                    contents = Data(contents[(newline + 1)...])
                } else {
                    contents = Data()
                }
                try contents.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("Diagnostics write failed: %@", error.localizedDescription)
        }

        if Date().timeIntervalSince(lastPreviewUpdate) > 0.5 || line.contains("[ERROR]") {
            refresh()
        }
    }

    func refresh() {
        guard let data = try? Data(contentsOf: fileURL),
              let value = String(data: data, encoding: .utf8) else { return }
        recentText = String(value.suffix(previewBytes))
        lastPreviewUpdate = Date()
    }

    func copyRecent(maxLines: Int = 200) -> String {
        let value = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? recentText
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines).joined(separator: "\n")
    }

    func exportURL() -> URL { fileURL }

    static func safeURL(_ url: URL?) -> String {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return url?.absoluteString ?? "<nil>"
        }
        if components.user != nil { components.user = "[redacted]" }
        if components.password != nil { components.password = "[redacted]" }
        let sensitive = ["token", "access_token", "auth", "authorization", "key", "api_key", "password", "sign", "signature"]
        components.queryItems = components.queryItems?.map { item in
            sensitive.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "[redacted]")
                : item
        }
        return components.string ?? "<invalid-url>"
    }
}

@MainActor
final class BrowserController: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var showsNavigationProgress = false
    @Published private(set) var diagnostic = "等待输入网址"
    @Published var webViewID = UUID()

    var webView: WKWebView?
    var retainedCoordinator: AnyObject?
    private var progressObservation: NSKeyValueObservation?
    private var requestedKey: String?
    private var navigationStartedAt: Date?

    func observeProgress(of view: WKWebView) {
        progressObservation?.invalidate()
        progressObservation = view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.estimatedProgress = observed.estimatedProgress
                if observed.isLoading { self.showsNavigationProgress = true }
            }
        }
    }

    private func finishProgress() {
        estimatedProgress = 1
        showsNavigationProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.estimatedProgress >= 1 else { return }
            self.showsNavigationProgress = false
            self.estimatedProgress = 0
        }
    }

    func load(_ url: URL) {
        guard let webView else {
            AppDiagnostics.shared.log("NAV", "WebView 尚未就绪，忽略导航请求")
            return
        }

        let key = Self.navigationKey(url)
        if isLoading, requestedKey == key {
            AppDiagnostics.shared.log("NAV", "忽略重复导航 url=\(AppDiagnostics.safeURL(url))")
            return
        }

        requestedKey = key
        navigationStartedAt = Date()
        estimatedProgress = 0.03
        showsNavigationProgress = true
        diagnostic = "阶段：正在加载\n地址：\(url.absoluteString)"
        AppDiagnostics.shared.log("NAV", "用户发起导航 url=\(AppDiagnostics.safeURL(url))")
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        update(webView)
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        requestedKey = nil
        AppDiagnostics.shared.log("NAV", "用户后退")
        webView.goBack()
    }

    func goForward() {
        guard let webView, webView.canGoForward else { return }
        requestedKey = nil
        AppDiagnostics.shared.log("NAV", "用户前进")
        webView.goForward()
    }

    func reload() {
        guard let webView else { return }
        requestedKey = webView.url.map(Self.navigationKey)
        navigationStartedAt = Date()
        AppDiagnostics.shared.log("NAV", "用户刷新 url=\(AppDiagnostics.safeURL(webView.url))")
        webView.reload()
        update(webView)
    }

    func stopLoading() {
        guard let webView, webView.isLoading else { return }
        AppDiagnostics.shared.log("NAV", "用户停止加载")
        webView.stopLoading()
        isLoading = false
        finishProgress()
        update(webView)
    }

    func goHome() {
        guard let url = URL(string: "https://www.google.com/") else { return }
        load(url)
    }

    func rebuildWebView() {
        AppDiagnostics.shared.log("WEBKIT", "用户请求重建 WKWebView")
        webView?.stopLoading()
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        retainedCoordinator = nil
        requestedKey = nil
        navigationStartedAt = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        diagnostic = "阶段：浏览器已重置"
        webViewID = UUID()
    }

    func dispose() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        retainedCoordinator = nil
    }

    static func navigationKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? url.absoluteString
    }

    func recordStage(_ stage: String, view: WKWebView) {
        let address = view.url?.absoluteString ?? requestedKey ?? "未知"
        diagnostic = "阶段：\(stage)\n地址：\(address)\n加载状态：\(view.isLoading ? "加载中" : "已停止")"
        AppDiagnostics.shared.log("WEBKIT", "\(stage) url=\(AppDiagnostics.safeURL(view.url)) loading=\(view.isLoading)")
    }

    func recordError(_ error: Error, stage: String, view: WKWebView) {
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled {
            AppDiagnostics.shared.log("NAV", "导航取消 -999（新导航替代或用户停止），不视为连接故障 url=\(AppDiagnostics.safeURL(view.url))")
            update(view)
            return
        }

        let elapsed = navigationStartedAt.map { String(format: "%.1f 秒", Date().timeIntervalSince($0)) } ?? "未知"
        let failedURL = value.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        diagnostic = "阶段：\(stage)\n耗时：\(elapsed)\n地址：\(view.url?.absoluteString ?? "未知")\n失败地址：\(failedURL ?? "未提供")\n错误域：\(value.domain)\n错误码：\(value.code)\n描述：\(value.localizedDescription)"
        requestedKey = nil
        finishProgress()
        AppDiagnostics.shared.log("ERROR", "stage=\(stage) elapsed=\(elapsed) domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription) url=\(AppDiagnostics.safeURL(view.url))")
        update(view)
    }

    func navigationFinished(_ view: WKWebView) {
        requestedKey = nil
        diagnostic = "阶段：加载完成\n地址：\(view.url?.absoluteString ?? "未知")"
        finishProgress()
        update(view)
    }

    func update(_ view: WKWebView) {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = view.isLoading
    }
}

struct BrowserView: UIViewRepresentable {
    let address: String
    @ObservedObject var controller: BrowserController
    let onCapture: (URL, [HTTPCookie], Bool) -> Void
    let onAddressChange: (String) -> Void
    let onNewTab: (URL?) -> Void
    let isSniffingEnabled: Bool
    let isVideoSniffingEnabled: Bool
    let isAdRedirectBlockingEnabled: Bool
    let isPopupBlockingEnabled: Bool
    let customAdDomains: String
    let isDesktopMode: Bool
    let stripMobilePrefix: Bool
    let zoomLevel: Double

    private static let sniffingScript = """
    (() => {
      if (window.__hlsSnifferInstalled) return;
      window.__hlsSnifferInstalled = true;
      const seen = new Set();
      const notify = value => {
        try {
          const raw = value && value.url ? value.url : value;
          const absolute = new URL(String(raw), location.href).href;
          if (!/\\.m3u8(?:[/?#]|$)/i.test(absolute) || seen.has(absolute)) return;
          seen.add(absolute);
          if (seen.size > 300) seen.clear();
          window.webkit.messageHandlers.hls.postMessage(absolute);
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      window.fetch = function(input, init) {
        const requestURL = input && input.url ? input.url : input;
        notify(requestURL);
        const promise = originalFetch.apply(this, arguments);
        promise.then(response => {
          const type = (response.headers.get('content-type') || '').toLowerCase();
          if (/mpegurl|vnd\\.apple\\.mpegurl/.test(type)) notify(response.url);
          else if (response.url && /\\.m3u8(?:[/?#]|$)/i.test(response.url)) notify(response.url);
          else response.clone().text().then(body => {
            if (body.trimStart().replace(/^\\uFEFF/, '').startsWith('#EXTM3U')) notify(response.url);
          }).catch(() => {});
        }).catch(() => {});
        return promise;
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__hlsURL = url;
        notify(url);
        return originalOpen.apply(this, arguments);
      };
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try {
            const type = (this.getResponseHeader('content-type') || '').toLowerCase();
            const body = typeof this.responseText === 'string' ? this.responseText : '';
            if (/mpegurl|vnd\\.apple\\.mpegurl/.test(type) ||
                body.trimStart().replace(/^\\uFEFF/, '').startsWith('#EXTM3U')) {
              notify(this.responseURL || this.__hlsURL);
            }
          } catch (_) {}
        });
        return originalSend.apply(this, arguments);
      };
      try {
        const mediaSrc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (mediaSrc && mediaSrc.set && mediaSrc.get) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            configurable: true,
            enumerable: mediaSrc.enumerable,
            get: mediaSrc.get,
            set(value) { notify(value); return mediaSrc.set.call(this, value); }
          });
        }
      } catch (_) {}
      const scan = () => {
        performance.getEntriesByType('resource').forEach(entry => {
          if (/\\.m3u8(?:[/?#]|$)/i.test(entry.name)) notify(entry.name);
        });
        document.querySelectorAll('video,source').forEach(node => {
          if (node.currentSrc) notify(node.currentSrc);
          if (node.src) notify(node.src);
        });
      };
      try {
        new PerformanceObserver(list => list.getEntries().forEach(entry => {
          if (/\\.m3u8(?:[/?#]|$)/i.test(entry.name)) notify(entry.name);
        })).observe({entryTypes:['resource']});
      } catch (_) {}
      try {
        new MutationObserver(scan).observe(document.documentElement,
          {childList:true,subtree:true,attributes:true,attributeFilter:['src']});
      } catch (_) {}
      scan();
    })();
    """

    private static let videoSniffingScript = #"""
    (() => {
      if (window.__videoSnifferInstalled) return;
      window.__videoSnifferInstalled = true;
      const seen = new Set();
      const extensions = /\.(?:mp4|m4v|mov|webm|mkv|avi)(?:[?#]|$)/i;
      const notify = (value, mime = "") => {
        try {
          const raw = value && value.url ? value.url : value;
          const url = new URL(String(raw), location.href);
          if (!/^https?:$/.test(url.protocol) || (!extensions.test(url.href) && !/^(?:video\/(?:mp4|quicktime|webm|x-m4v|x-msvideo|x-matroska))$/i.test(mime))) return;
          if (/\.(?:ts|m4s)(?:[?#]|$)/i.test(url.href)) return;
          if (seen.has(url.href)) return;
          seen.add(url.href);
          if (seen.size > 300) seen.clear();
          window.webkit.messageHandlers.video.postMessage(url.href);
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      window.fetch = function(input, init) {
        const promise = originalFetch.apply(this, arguments);
        promise.then(response => notify(response.url || (input && input.url ? input.url : input),
          response.headers.get('content-type') || '')).catch(() => {});
        return promise;
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__videoURL = url;
        notify(url);
        return originalOpen.apply(this, arguments);
      };
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try { notify(this.responseURL || this.__videoURL, this.getResponseHeader('content-type') || ''); }
          catch (_) {}
        });
        return originalSend.apply(this, arguments);
      };
      try {
        const mediaSrc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (mediaSrc && mediaSrc.set && mediaSrc.get) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            configurable: true,
            enumerable: mediaSrc.enumerable,
            get: mediaSrc.get,
            set(value) { notify(value); return mediaSrc.set.call(this, value); }
          });
        }
      } catch (_) {}
      const scan = () => {
        performance.getEntriesByType('resource').forEach(entry => notify(entry.name));
        document.querySelectorAll('video,source').forEach(node => {
          if (node.currentSrc) notify(node.currentSrc);
          if (node.src) notify(node.src);
        });
      };
      try {
        new PerformanceObserver(list => list.getEntries().forEach(entry => notify(entry.name)))
          .observe({entryTypes:['resource']});
      } catch (_) {}
      try {
        new MutationObserver(scan).observe(document.documentElement,
          {childList:true,subtree:true,attributes:true,attributeFilter:['src']});
      } catch (_) {}
      scan();
    })();
    """#

    private func installContentRules(in contentController: WKUserContentController, coordinator: Coordinator) {
        guard isAdRedirectBlockingEnabled else {
            contentController.removeAllContentRuleLists()
            coordinator.adRulesSignature = nil
            return
        }
        let builtIn = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "adservice.google.com", "popads.net", "popcash.net", "propellerads.com",
            "taboola.com", "outbrain.com", "adnxs.com", "exoclick.com",
            "trafficjunky.net", "adsterra.com"
        ]
        let custom = customAdDomains.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { domain in
                guard !domain.isEmpty, domain.utf8.count <= 253 else { return false }
                let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.count >= 2 else { return false }
                return labels.allSatisfy { label in
                    label.utf8.count <= 63 &&
                    label.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
                }
            }
        let domains = Array(Set(builtIn + custom)).sorted().prefix(1200)
        let signature = domains.joined(separator: "|")
        guard coordinator.adRulesSignature != signature else { return }
        coordinator.adRulesSignature = signature
        let domainList = Array(domains)
        let store = WKContentRuleListStore.default()

        // WebKit rejects an entire content-rule list when even one expression is
        // unsupported. Compile as a whole first, then bisect failed batches so a
        // malformed custom domain cannot disable every valid ad rule.
        func compile(_ subset: [String], completion: @escaping ([WKContentRuleList]) -> Void) {
            guard !subset.isEmpty else {
                completion([])
                return
            }
            let rules: [[String: Any]] = subset.map { domain in
                let escaped = NSRegularExpression.escapedPattern(for: domain)
                return [
                    "trigger": ["url-filter": "^https?://([^/]+\\.)*\(escaped)([/:?#]|$)"],
                    "action": ["type": "block"]
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rules),
                  let encoded = String(data: data, encoding: .utf8) else {
                completion([])
                return
            }
            let identifier = "BrowserAdRules-\(String(signature.hashValue.magnitude))-\(UUID().uuidString)"
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encoded
            ) { list, error in
                DispatchQueue.main.async {
                    guard coordinator.adRulesSignature == signature else {
                        completion([])
                        return
                    }
                    if let list {
                        completion([list])
                        return
                    }
                    if subset.count == 1 {
                        let detail = error as NSError?
                        AppDiagnostics.shared.log("ERROR", "跳过无法编译的广告域名：\(subset[0]) error=\(detail?.localizedDescription ?? "未知错误")")
                        completion([])
                        return
                    }
                    let middle = subset.count / 2
                    compile(Array(subset[..<middle])) { left in
                        compile(Array(subset[middle...])) { right in
                            completion(left + right)
                        }
                    }
                }
            }
        }

        compile(domainList) { lists in
            guard coordinator.adRulesSignature == signature else { return }
            contentController.removeAllContentRuleLists()
            lists.forEach { contentController.add($0) }
            if !lists.isEmpty {
                coordinator.webView?.reload()
                AppDiagnostics.shared.log("ADBLOCK", "网页资源规则已加载：\(domainList.count) 个域名，拆分规则组 \(lists.count) 组")
            } else {
                AppDiagnostics.shared.log("ERROR", "广告规则未能编译，未加载任何规则")
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        if let existing = controller.retainedCoordinator as? Coordinator {
            existing.onCapture = onCapture
            existing.onAddressChange = onAddressChange
            existing.onNewTab = onNewTab
            return existing
        }
        let coordinator = Coordinator(
            controller: controller,
            onCapture: onCapture,
            onAddressChange: onAddressChange,
            onNewTab: onNewTab,
            isSniffingEnabled: isSniffingEnabled,
            isVideoSniffingEnabled: isVideoSniffingEnabled,
            isAdRedirectBlockingEnabled: isAdRedirectBlockingEnabled,
            isPopupBlockingEnabled: isPopupBlockingEnabled,
            customAdDomains: customAdDomains
        )
        controller.retainedCoordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        if let existing = controller.webView {
            let settingsChanged =
                context.coordinator.isDesktopMode != isDesktopMode ||
                context.coordinator.stripMobilePrefix != stripMobilePrefix ||
                context.coordinator.isSniffingEnabled != isSniffingEnabled ||
                context.coordinator.isVideoSniffingEnabled != isVideoSniffingEnabled ||
                context.coordinator.isAdRedirectBlockingEnabled != isAdRedirectBlockingEnabled ||
                context.coordinator.customAdDomains != customAdDomains
            existing.navigationDelegate = context.coordinator
            existing.uiDelegate = context.coordinator
            controller.observeProgress(of: existing)
            existing.customUserAgent = isDesktopMode
                ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
                : nil
            context.coordinator.isDesktopMode = isDesktopMode
            context.coordinator.stripMobilePrefix = stripMobilePrefix
            context.coordinator.zoomLevel = zoomLevel
            existing.evaluateJavaScript("document.documentElement.style.zoom = '\(zoomLevel)'", completionHandler: nil)
            context.coordinator.isSniffingEnabled = isSniffingEnabled
            context.coordinator.isVideoSniffingEnabled = isVideoSniffingEnabled
            context.coordinator.isAdRedirectBlockingEnabled = isAdRedirectBlockingEnabled
            context.coordinator.isPopupBlockingEnabled = isPopupBlockingEnabled
            context.coordinator.customAdDomains = customAdDomains
            let contentController = existing.configuration.userContentController
            contentController.removeAllUserScripts()
            if isSniffingEnabled {
                contentController.addUserScript(WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            if isVideoSniffingEnabled {
                contentController.addUserScript(WKUserScript(source: Self.videoSniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            installContentRules(in: contentController, coordinator: context.coordinator)
            context.coordinator.webView = existing
            if settingsChanged, existing.url != nil { existing.reload() }
            return existing
        }
        let contentController = WKUserContentController()
        if isSniffingEnabled {
            contentController.addUserScript(
                WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        if isVideoSniffingEnabled {
            contentController.addUserScript(WKUserScript(source: Self.videoSniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        contentController.add(WeakScriptMessageHandler(context.coordinator), name: "hls")
        contentController.add(WeakScriptMessageHandler(context.coordinator), name: "video")
        installContentRules(in: contentController, coordinator: context.coordinator)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if isDesktopMode { webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" }
        context.coordinator.isDesktopMode = isDesktopMode
        context.coordinator.stripMobilePrefix = stripMobilePrefix
        context.coordinator.zoomLevel = zoomLevel
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.refreshPage), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        context.coordinator.webView = webView
        controller.webView = webView
        controller.observeProgress(of: webView)

        // Initial navigation occurs once, only when a real URL was supplied.
        if let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil {
            controller.load(url)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onAddressChange = onAddressChange
        context.coordinator.onNewTab = onNewTab
        context.coordinator.isAdRedirectBlockingEnabled = isAdRedirectBlockingEnabled
        context.coordinator.isPopupBlockingEnabled = isPopupBlockingEnabled
        context.coordinator.customAdDomains = customAdDomains
        installContentRules(in: webView.configuration.userContentController, coordinator: context.coordinator)
        let desktopModeChanged = context.coordinator.isDesktopMode != isDesktopMode
        let stripPrefixChanged = context.coordinator.stripMobilePrefix != stripMobilePrefix
        if desktopModeChanged || stripPrefixChanged {
            context.coordinator.isDesktopMode = isDesktopMode
            context.coordinator.stripMobilePrefix = stripMobilePrefix
            webView.customUserAgent = isDesktopMode ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" : nil
            if webView.url != nil { webView.reload() }
        }
        if context.coordinator.zoomLevel != zoomLevel {
            context.coordinator.zoomLevel = zoomLevel
            webView.evaluateJavaScript("document.documentElement.style.zoom = '\(zoomLevel)'", completionHandler: nil)
        }
        if controller.webView !== webView {
            controller.webView = webView
            context.coordinator.webView = webView
        }

        // The address field is presentation state, never a navigation command.
        // All user navigation is routed explicitly through BrowserController.
        let sniffingChanged = context.coordinator.isSniffingEnabled != isSniffingEnabled
        let videoSniffingChanged = context.coordinator.isVideoSniffingEnabled != isVideoSniffingEnabled
        if sniffingChanged || videoSniffingChanged {
            context.coordinator.isSniffingEnabled = isSniffingEnabled
            context.coordinator.isVideoSniffingEnabled = isVideoSniffingEnabled
            let contentController = webView.configuration.userContentController
            contentController.removeAllUserScripts()
            if isSniffingEnabled {
                contentController.addUserScript(WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            if isVideoSniffingEnabled {
                contentController.addUserScript(WKUserScript(source: Self.videoSniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            AppDiagnostics.shared.log("SNIFF", "嗅探开关切换 HLS=\(isSniffingEnabled) 普通视频=\(isVideoSniffingEnabled)")
            if webView.url != nil { webView.reload() }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Keep inactive tab WebViews and their navigation state alive.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let controller: BrowserController
        weak var webView: WKWebView?
        var onCapture: (URL, [HTTPCookie], Bool) -> Void
        var onAddressChange: (String) -> Void
        var onNewTab: (URL?) -> Void
        var isSniffingEnabled: Bool
        var isVideoSniffingEnabled: Bool
        var isAdRedirectBlockingEnabled: Bool
        var isPopupBlockingEnabled: Bool
        var customAdDomains: String
        var isDesktopMode = false
        var stripMobilePrefix = false
        var zoomLevel = 1.0
        var adRulesSignature: String?

        private static let builtInAdDomains: Set<String> = [
            "doubleclick.net",
            "googlesyndication.com",
            "googleadservices.com",
            "adservice.google.com",
            "popads.net",
            "popcash.net",
            "propellerads.com",
            "taboola.com",
            "outbrain.com",
            "adnxs.com",
            "exoclick.com",
            "trafficjunky.net",
            "adsterra.com"
        ]

        init(
            controller: BrowserController,
            onCapture: @escaping (URL, [HTTPCookie], Bool) -> Void,
            onAddressChange: @escaping (String) -> Void,
            onNewTab: @escaping (URL?) -> Void,
            isSniffingEnabled: Bool,
            isVideoSniffingEnabled: Bool,
            isAdRedirectBlockingEnabled: Bool,
            isPopupBlockingEnabled: Bool,
            customAdDomains: String
        ) {
            self.controller = controller
            self.onCapture = onCapture
            self.onAddressChange = onAddressChange
            self.onNewTab = onNewTab
            self.isSniffingEnabled = isSniffingEnabled
            self.isVideoSniffingEnabled = isVideoSniffingEnabled
            self.isAdRedirectBlockingEnabled = isAdRedirectBlockingEnabled
            self.isPopupBlockingEnabled = isPopupBlockingEnabled
            self.customAdDomains = customAdDomains
        }

        private func isBlockedAdDomain(_ host: String) -> Bool {
            let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let custom = customAdDomains
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && !$0.contains("/") && !$0.contains(":") && !$0.contains(" ") }
            let domains = Self.builtInAdDomains.union(custom)
            return domains.contains { normalizedHost == $0 || normalizedHost.hasSuffix("." + $0) }
        }

        private func isHLSPlaylistURL(_ url: URL) -> Bool {
            url.pathExtension.lowercased() == "m3u8"
        }

        private func isHLSPlaylistMIME(_ mime: String) -> Bool {
            let value = mime.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? mime.lowercased()
            return ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(value)
        }

        private func shouldBlock(_ url: URL, isNewWindow: Bool, isMainFrame: Bool) -> Bool {
            if isNewWindow && isPopupBlockingEnabled {
                AppDiagnostics.shared.log("ADBLOCK", "已拦截弹窗 url=\(AppDiagnostics.safeURL(url))")
                return true
            }
            if isMainFrame, isAdRedirectBlockingEnabled, let host = url.host, isBlockedAdDomain(host) {
                AppDiagnostics.shared.log("ADBLOCK", "已拦截广告域名跳转 host=\(host)")
                return true
            }
            return false
        }

        private func capture(_ url: URL, isDirectVideo: Bool) {
            AppDiagnostics.shared.log("SNIFF", "捕获\(isDirectVideo ? "普通视频" : "HLS")候选 url=\(AppDiagnostics.safeURL(url))")
            guard let webView else {
                onCapture(url, [], isDirectVideo)
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async { self?.onCapture(url, cookies, isDirectVideo) }
            }
        }

        @objc func refreshPage() {
            controller.reload()
            webView?.scrollView.refreshControl?.endRefreshing()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ["hls", "video"].contains(message.name),
                  let value = message.body as? String,
                  let url = URL(string: value) else { return }
            capture(url, isDirectVideo: message.name == "video")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isNewWindow = navigationAction.targetFrame == nil
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if isSniffingEnabled, isMainFrame, isHLSPlaylistURL(url) {
                // Sniffing is observational: never cancel a page's own HLS navigation.
                AppDiagnostics.shared.log("SNIFF", "捕获 HLS 主文档导航（保持网页原生播放） url=\(AppDiagnostics.safeURL(url))")
                capture(url, isDirectVideo: false)
            }
            if isVideoSniffingEnabled, isMainFrame,
               ["mp4", "m4v", "mov", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased()) {
                capture(url, isDirectVideo: true)
            }
            if shouldBlock(url, isNewWindow: isNewWindow, isMainFrame: isMainFrame) {
                decisionHandler(.cancel)
                return
            }
            if isMainFrame, isDesktopMode, stripMobilePrefix,
               let host = url.host?.lowercased(), host.hasPrefix("m."),
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.host = String(host.dropFirst(2))
                if let target = components.url {
                    AppDiagnostics.shared.log("NAV", "桌面版移除移动站前缀：\(host) → \(target.host ?? "")")
                    if isNewWindow {
                        onNewTab(target)
                    } else {
                        var request = navigationAction.request
                        request.url = target
                        webView.load(request)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            if isNewWindow {
                AppDiagnostics.shared.log("TAB", "网页请求在新标签打开 url=\(AppDiagnostics.safeURL(url))")
                onNewTab(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            if let url = navigationAction.request.url {
                AppDiagnostics.shared.log("NAV", "拒绝创建独立网页窗口（已由导航策略转入当前标签） url=\(AppDiagnostics.safeURL(url))")
            }
            // Returning the existing webView here is invalid: WebKit expects a
            // newly-created view using the supplied configuration, or nil.
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                let mime = navigationResponse.response.mimeType ?? "未知"
                let responseURL = navigationResponse.response.url
                AppDiagnostics.shared.log("RESPONSE", "主文档响应 mime=\(mime) url=\(AppDiagnostics.safeURL(responseURL))")
                if isSniffingEnabled, isHLSPlaylistMIME(mime), let responseURL {
                    AppDiagnostics.shared.log("SNIFF", "主文档响应识别为 HLS mime=\(mime)（允许网页原生处理）")
                    capture(responseURL, isDirectVideo: false)
                }
                if isVideoSniffingEnabled, ["video/mp4", "video/quicktime", "video/webm", "video/x-m4v", "video/x-msvideo", "video/x-matroska"].contains(mime.lowercased()), let responseURL {
                    capture(responseURL, isDirectVideo: true)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            controller.recordStage("开始加载", view: webView)
            controller.update(webView)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            AppDiagnostics.shared.log("NAV", "服务器重定向 url=\(AppDiagnostics.safeURL(webView.url))")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            controller.recordStage("页面开始呈现", view: webView)
            controller.update(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.navigationFinished(webView)
            webView.evaluateJavaScript("document.documentElement.style.zoom = '\(zoomLevel)'", completionHandler: nil)
            if let url = webView.url { onAddressChange(url.absoluteString) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            controller.recordError(error, stage: "页面加载失败", view: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.recordError(error, stage: "连接阶段失败", view: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppDiagnostics.shared.log("WEBKIT", "网页内容进程终止 url=\(AppDiagnostics.safeURL(webView.url))")
            controller.recordStage("网页内容进程终止", view: webView)
            controller.update(webView)
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
