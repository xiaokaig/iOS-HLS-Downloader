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
    @Published private(set) var diagnostic = "等待输入网址"
    @Published var webViewID = UUID()

    weak var webView: WKWebView?
    private var requestedKey: String?
    private var navigationStartedAt: Date?

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
        update(webView)
    }

    func goHome() {
        guard let url = URL(string: "https://www.google.com/") else { return }
        load(url)
    }

    func rebuildWebView() {
        AppDiagnostics.shared.log("WEBKIT", "用户请求重建 WKWebView")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        requestedKey = nil
        navigationStartedAt = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        diagnostic = "阶段：浏览器已重置"
        webViewID = UUID()
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
        AppDiagnostics.shared.log("ERROR", "stage=\(stage) elapsed=\(elapsed) domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription) url=\(AppDiagnostics.safeURL(view.url))")
        update(view)
    }

    func navigationFinished(_ view: WKWebView) {
        requestedKey = nil
        diagnostic = "阶段：加载完成\n地址：\(view.url?.absoluteString ?? "未知")"
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
    let onCapture: (URL, [HTTPCookie]) -> Void
    let onAddressChange: (String) -> Void
    let isSniffingEnabled: Bool

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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onCapture: onCapture,
            onAddressChange: onAddressChange,
            isSniffingEnabled: isSniffingEnabled
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        if isSniffingEnabled {
            contentController.addUserScript(
                WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        contentController.add(WeakScriptMessageHandler(context.coordinator), name: "hls")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true

        context.coordinator.webView = webView
        controller.webView = webView

        // Initial navigation occurs once, only when a real URL was supplied.
        if let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil {
            controller.load(url)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onAddressChange = onAddressChange
        if controller.webView !== webView {
            controller.webView = webView
            context.coordinator.webView = webView
        }

        // The address field is presentation state, never a navigation command.
        // All user navigation is routed explicitly through BrowserController.
        if context.coordinator.isSniffingEnabled != isSniffingEnabled {
            context.coordinator.isSniffingEnabled = isSniffingEnabled
            let contentController = webView.configuration.userContentController
            contentController.removeAllUserScripts()
            if isSniffingEnabled {
                contentController.addUserScript(
                    WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                )
            }
            AppDiagnostics.shared.log("HLS", "嗅探开关切换 enabled=\(isSniffingEnabled)")
            if webView.url != nil { webView.reload() }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if coordinator.controller.webView === webView {
            coordinator.controller.webView = nil
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let controller: BrowserController
        weak var webView: WKWebView?
        var onCapture: (URL, [HTTPCookie]) -> Void
        var onAddressChange: (String) -> Void
        var isSniffingEnabled: Bool

        init(
            controller: BrowserController,
            onCapture: @escaping (URL, [HTTPCookie]) -> Void,
            onAddressChange: @escaping (String) -> Void,
            isSniffingEnabled: Bool
        ) {
            self.controller = controller
            self.onCapture = onCapture
            self.onAddressChange = onAddressChange
            self.isSniffingEnabled = isSniffingEnabled
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "hls",
                  let value = message.body as? String,
                  let url = URL(string: value) else { return }
            guard let webView else {
                onCapture(url, [])
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async { self?.onCapture(url, cookies) }
            }
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
            if navigationAction.targetFrame == nil {
                AppDiagnostics.shared.log("NAV", "网页请求新窗口，交由当前标签打开 url=\(AppDiagnostics.safeURL(url))")
            }
            // WebKit owns links, redirects, forms, history and frame navigation.
            // Never call load() from this callback.
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            AppDiagnostics.shared.log("NAV", "window.open 在当前标签承载 url=\(AppDiagnostics.safeURL(navigationAction.request.url))")
            return webView
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                AppDiagnostics.shared.log("RESPONSE", "主文档响应 mime=\(navigationResponse.response.mimeType ?? "未知") url=\(AppDiagnostics.safeURL(navigationResponse.response.url))")
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
            if let url = webView.url { onAddressChange(url.absoluteString) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.navigationFinished(webView)
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
