import SwiftUI
import WebKit

@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()
    @Published private(set) var recentText = "日志初始化中"
    private let fileURL: URL
    private let maxBytes = 2 * 1024 * 1024

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("app-diagnostics.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        refresh()
        log("APP", "诊断日志启动；日志文件：app-diagnostics.log")
    }

    func log(_ category: String, _ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let size = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size + data.count > maxBytes {
                try Data().write(to: fileURL, options: .atomic)
                let marker = "[\(formatter.string(from: Date()))] [LOG] 日志达到 2MB，已滚动清理旧记录\n"
                try marker.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { NSLog("Diagnostics write failed: %@", error.localizedDescription) }
        refresh()
    }

    func refresh() {
        guard let data = try? Data(contentsOf: fileURL), let value = String(data: data, encoding: .utf8) else { return }
        recentText = String(value.suffix(24000))
    }

    func copyAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? recentText
    }

    func exportURL() -> URL { fileURL }

    static func safeURL(_ url: URL?) -> String {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return url?.absoluteString ?? "<nil>" }
        if components.user != nil { components.user = "[redacted]" }
        if components.password != nil { components.password = "[redacted]" }
        let sensitive = ["token", "access_token", "auth", "authorization", "key", "api_key", "password", "sign", "signature"]
        components.queryItems = components.queryItems?.map { item in
            sensitive.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "[redacted]") : item
        }
        return components.string ?? url?.absoluteString ?? "<invalid-url>"
    }
}

@MainActor
final class BrowserController: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var diagnostic = "尚未开始网页加载"
    @Published var webViewID = UUID()
    weak var webView: WKWebView?
    private(set) var lastAddress = ""
    private var navigationStartedAt: Date?

    func load(_ url: URL) {
        lastAddress = url.absoluteString
        navigationStartedAt = Date()
        diagnostic = "阶段：已发起请求\n地址：\(url.absoluteString)"
        AppDiagnostics.shared.log("NAV", "手动发起导航 url=\(AppDiagnostics.safeURL(url))")
        webView?.load(URLRequest(url: url))
    }
    func goBack() { AppDiagnostics.shared.log("NAV", "点击后退"); webView?.goBack() }
    func goForward() { AppDiagnostics.shared.log("NAV", "点击前进"); webView?.goForward() }
    func reload() { AppDiagnostics.shared.log("NAV", "点击刷新 url=\(AppDiagnostics.safeURL(webView?.url))"); webView?.reload() }
    func goHome() { if let url = URL(string: "https://www.google.com") { load(url) } }
    func rebuildWebView() {
        AppDiagnostics.shared.log("WEBKIT", "请求重建 WKWebView")
        webView = nil
        lastAddress = ""
        diagnostic = "阶段：正在重建 WKWebView"
        webViewID = UUID()
    }
    func recordStage(_ stage: String, view: WKWebView) {
        diagnostic = "阶段：\(stage)\n地址：\(view.url?.absoluteString ?? lastAddress)\n加载状态：\(view.isLoading ? "加载中" : "未加载")"
        AppDiagnostics.shared.log("WEBKIT", "\(stage) url=\(AppDiagnostics.safeURL(view.url)) loading=\(view.isLoading) title=\(view.title ?? "")")
    }
    func recordError(_ error: Error, stage: String, view: WKWebView) {
        let value = error as NSError
        let elapsed = navigationStartedAt.map { String(format: "%.1f 秒", Date().timeIntervalSince($0)) } ?? "未知"
        let failedURL = value.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        diagnostic = "阶段：\(stage)\n耗时：\(elapsed)\n地址：\(view.url?.absoluteString ?? lastAddress)\n失败地址：\(failedURL ?? "未提供")\n错误域：\(value.domain)\n错误码：\(value.code)\n描述：\(value.localizedDescription)"
        isLoading = false
        AppDiagnostics.shared.log("ERROR", "stage=\(stage) elapsed=\(elapsed) domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription) failingURL=\(failedURL ?? "<nil>") userInfo=\(value.userInfo)")
    }
    func update(_ view: WKWebView) {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = view.isLoading
        if let url = view.url { lastAddress = url.absoluteString }
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
          const notify = value => {
            try {
              const raw = value && value.url ? value.url : value;
              const absolute = new URL(String(raw), location.href).href;
              if (/m3u8(?:[/?#]|$)/i.test(absolute)) window.webkit.messageHandlers.hls.postMessage(absolute);
            } catch (_) {}
          };
          const originalFetch = window.fetch;
          window.fetch = function(input, init) {
            const raw = input && input.url ? input.url : input;
            notify(raw);
            const promise = originalFetch.apply(this, arguments);
            promise.then(response => {
              const type = (response.headers.get('content-type') || '').toLowerCase();
              if (/mpegurl|vnd\\.apple\\.mpegurl/.test(type)) notify(response.url);
              else response.clone().text().then(body => {
                if (body.trimStart().replace(/^\\uFEFF/, '').startsWith('#EXTM3U')) notify(response.url);
              }).catch(() => {});
            }).catch(() => {});
            return promise;
          };
          const originalOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url) { this.__hlsURL = url; return originalOpen.apply(this, arguments); };
          const originalSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function() {
            this.addEventListener('load', function() {
              try {
                const type = (this.getResponseHeader('content-type') || '').toLowerCase();
                const body = typeof this.responseText === 'string' ? this.responseText : '';
                if (/mpegurl|vnd\\.apple\\.mpegurl/.test(type) || body.trimStart().replace(/^\\uFEFF/, '').startsWith('#EXTM3U')) notify(this.responseURL || this.__hlsURL);
              } catch (_) {}
            });
            return originalSend.apply(this, arguments);
          };
          const scan = () => {
            performance.getEntriesByType('resource').forEach(entry => notify(entry.name));
            document.querySelectorAll('video,source').forEach(node => { if (node.currentSrc) notify(node.currentSrc); if (node.src) notify(node.src); });
          };
          try { new PerformanceObserver(list => list.getEntries().forEach(entry => notify(entry.name))).observe({entryTypes:['resource']}); } catch (_) {}
          new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
          scan();
        })();
        """

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onCapture: onCapture, onAddressChange: onAddressChange, isSniffingEnabled: isSniffingEnabled) }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()

        if isSniffingEnabled {
            userController.addUserScript(WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        userController.add(WeakScriptMessageHandler(context.coordinator), name: "hls")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        controller.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: address), url.host != nil { controller.load(url) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onAddressChange = onAddressChange
        if context.coordinator.isSniffingEnabled != isSniffingEnabled {
            context.coordinator.isSniffingEnabled = isSniffingEnabled
            let userController = webView.configuration.userContentController
            userController.removeAllUserScripts()
            if isSniffingEnabled {
                userController.addUserScript(WKUserScript(source: Self.sniffingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            webView.reload()
        }
        if controller.webView !== webView { controller.webView = webView }
        if controller.lastAddress != address, let url = URL(string: address), url.host != nil { controller.load(url) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: BrowserController
        weak var webView: WKWebView?
        var onCapture: (URL, [HTTPCookie]) -> Void
        var onAddressChange: (String) -> Void
        var isSniffingEnabled: Bool
        init(controller: BrowserController, onCapture: @escaping (URL,[HTTPCookie])->Void, onAddressChange: @escaping (String)->Void, isSniffingEnabled: Bool) {
            self.controller = controller; self.onCapture = onCapture; self.onAddressChange = onAddressChange; self.isSniffingEnabled = isSniffingEnabled
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? String, let url = URL(string: value) else { return }
            guard let webView else { onCapture(url, []); return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async { self?.onCapture(url, cookies) }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let request = navigationAction.request
            let type = navigationAction.navigationType.rawValue
            AppDiagnostics.shared.log("REQUEST", "action type=\(type) mainFrame=\(navigationAction.targetFrame?.isMainFrame.description ?? "nil") method=\(request.httpMethod ?? "GET") url=\(AppDiagnostics.safeURL(request.url))")
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let response = navigationResponse.response as? HTTPURLResponse {
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    let key = String(describing: pair.key)
                    if !["set-cookie", "authorization", "www-authenticate"].contains(key.lowercased()) { result[key] = String(describing: pair.value) }
                }
                AppDiagnostics.shared.log("RESPONSE", "status=\(response.statusCode) mime=\(response.mimeType ?? "nil") expectedLength=\(response.expectedContentLength) mainFrame=\(navigationResponse.isForMainFrame) url=\(AppDiagnostics.safeURL(response.url)) headers=\(headers)")
            } else {
                AppDiagnostics.shared.log("RESPONSE", "non-HTTP response mainFrame=\(navigationResponse.isForMainFrame) url=\(AppDiagnostics.safeURL(navigationResponse.response.url))")
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            AppDiagnostics.shared.log("NAV", "didStartProvisionalNavigation url=\(AppDiagnostics.safeURL(webView.url))")
            controller.recordStage("开始连接 / DNS / TLS", view: webView)
            controller.update(webView)
        }
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            AppDiagnostics.shared.log("NAV", "服务器重定向 currentURL=\(AppDiagnostics.safeURL(webView.url))")
            controller.recordStage("收到服务器重定向", view: webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            AppDiagnostics.shared.log("NAV", "didCommit url=\(AppDiagnostics.safeURL(webView.url))")
            controller.recordStage("已收到页面内容，开始提交", view: webView)
            controller.update(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AppDiagnostics.shared.log("NAV", "didFinish url=\(AppDiagnostics.safeURL(webView.url)) title=\(webView.title ?? "")")
            controller.recordStage("加载完成", view: webView)
            controller.update(webView)
            if let url = webView.url { onAddressChange(url.absoluteString) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            controller.recordError(error, stage: "页面加载失败", view: webView)
            controller.update(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.recordError(error, stage: "连接阶段失败", view: webView)
            controller.update(webView)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppDiagnostics.shared.log("WEBKIT", "WebContent 进程意外终止 url=\(AppDiagnostics.safeURL(webView.url))")
            controller.recordStage("WebContent 进程意外终止", view: webView)
            controller.update(webView)
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
