import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    let address: String
    let onCapture: (URL) -> Void
    let onAddressChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onAddressChange: onAddressChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let script = """
        (() => {
          const notify = (value) => {
            try {
              const raw = value && value.url ? value.url : value;
              const absolute = new URL(String(raw), location.href).href;
              if (/\\.m3u8(?:[?#]|$)/i.test(absolute)) {
                window.webkit.messageHandlers.hls.postMessage(absolute);
              }
            } catch (_) {}
          };
          const originalFetch = window.fetch;
          window.fetch = function(input, init) {
            notify(input && input.url ? input.url : input);
            return originalFetch.apply(this, arguments);
          };
          const originalOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url) {
            notify(url);
            return originalOpen.apply(this, arguments);
          };
          const scan = () => performance.getEntriesByType('resource').forEach(entry => notify(entry.name));
          try {
            new PerformanceObserver(list => list.getEntries().forEach(entry => notify(entry.name)))
              .observe({ entryTypes: ['resource'] });
          } catch (_) {}
          setInterval(scan, 2500);
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(WeakScriptMessageHandler(context.coordinator), name: "hls")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: address), url.scheme == "https" || url.scheme == "http" {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onAddressChange = onAddressChange
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onCapture: (URL) -> Void
        var onAddressChange: (String) -> Void

        init(onCapture: @escaping (URL) -> Void, onAddressChange: @escaping (String) -> Void) {
            self.onCapture = onCapture
            self.onAddressChange = onAddressChange
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? String, let url = URL(string: value) else { return }
            onCapture(url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { onAddressChange(url.absoluteString) }
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
