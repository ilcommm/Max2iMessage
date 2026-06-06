import SwiftUI
import WebKit

/// Отдельный WKWebView для окна входа — общий data store с мониторингом, но без JS-hook.
struct AuthWebView: NSViewRepresentable {
    let accountId: UUID
    var onAuthComplete: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthComplete: onAuthComplete)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WebViewConfigurationFactory.makeAuthConfiguration(accountId: accountId)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        WebViewConfigurationFactory.applyDefaults(to: webView)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: MaxWebSession.maxURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onAuthComplete = onAuthComplete
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var onAuthComplete: (() -> Void)?

        init(onAuthComplete: (() -> Void)?) {
            self.onAuthComplete = onAuthComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkAuth(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            .allow
        }

        private func checkAuth(in webView: WKWebView) {
            Task { @MainActor in
                do {
                    let value = try await webView.evaluateJavaScript("localStorage.getItem('__oneme_auth') != null")
                    if (value as? Bool) == true {
                        onAuthComplete?()
                    }
                } catch {
                    // Страница ещё грузится
                }
            }
        }
    }
}
