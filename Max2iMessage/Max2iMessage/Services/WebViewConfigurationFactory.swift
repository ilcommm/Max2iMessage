import Foundation
import WebKit

enum WebViewConfigurationFactory {
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func dataStore(for accountId: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: accountId)
    }

    static func makeMonitoringConfiguration(
        accountId: UUID,
        scriptHandler: WKScriptMessageHandler
    ) -> WKWebViewConfiguration {
        let config = makeBaseConfiguration(accountId: accountId)
        injectMonitorScript(into: config)

        config.userContentController.add(scriptHandler, name: MaxWebSession.bridgeName)

        return config
    }

    static func makeAuthConfiguration(accountId: UUID) -> WKWebViewConfiguration {
        makeBaseConfiguration(accountId: accountId)
    }

    private static func makeBaseConfiguration(accountId: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: accountId)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.setValue(true, forKey: "fullScreenEnabled")
        if #available(macOS 13.3, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }
        return config
    }

    static var monitorScriptSource: String? {
        guard let scriptURL = Bundle.main.url(forResource: "max-monitor", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: scriptURL, encoding: .utf8)
    }

    private static let bootstrapScriptSource = """
    (function(){window.__max2iMessageBootstrap=true;})();
    """

    static var monitorScriptLoaded: Bool {
        monitorScriptSource != nil
    }

    private static func injectMonitorScript(into config: WKWebViewConfiguration) {
        let bootstrap = WKUserScript(
            source: bootstrapScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(bootstrap)

        guard let source = monitorScriptSource else { return }

        let userScript = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
    }

    static func applyDefaults(to webView: WKWebView) {
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(true, forKey: "drawsBackground")
    }
}
