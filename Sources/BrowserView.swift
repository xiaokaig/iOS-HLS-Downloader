import SwiftUI
import WebKit

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
        webView?.load(URLRequest(url: url))
    }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func goHome() { if let url = URL(string: "https://www.google.com") { load(url) } }
    func rebuildWebView() {
        webView = nil
        lastAddress = ""
        diagnostic = "阶段：正在重建 WKWebView"
        webViewID = UUID()
    }
    func recordStage(_ stage: String, view: WKWebView) {
        diagnostic = "阶段：\(stage)\n地址：\(view.url?.absoluteString ?? lastAddress)\n加载状态：\(view.isLoading ? "加载中" : "未加载")"
    }
    func recordError(_ error: Error, stage: String, view: WKWebView) {
        let value = error as NSError
        let elapsed = navigationStartedAt.map { String(format: "%.1f 秒", Date().timeIntervalSince($0)) } ?? "未知"
        let failedURL = value.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        diagnostic = "阶段：\(stage)\n耗时：\(elapsed)\n地址：\(view.url?.absoluteString ?? lastAddress)\n失败地址：\(failedURL ?? "未提供")\n错误域：\(value.domain)\n错误码：\(value.code)\n描述：\(value.localizedDescription)"
        isLoading = false
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
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            controller.recordStage("开始连接 / DNS / TLS", view: webView)
            controller.update(webView)
        }
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            controller.recordStage("收到服务器重定向", view: webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            controller.recordStage("已收到页面内容，开始提交", view: webView)
            controller.update(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
