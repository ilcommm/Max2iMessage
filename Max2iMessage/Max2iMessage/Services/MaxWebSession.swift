import Foundation
import WebKit

protocol MaxWebSessionDelegate: AnyObject {
    func webSession(_ session: MaxWebSession, didReceive event: BridgeEvent)
    func webSession(_ session: MaxWebSession, didChangeAuth isAuthenticated: Bool)
    func webSessionDidFinishNavigation(_ session: MaxWebSession)
    func webSessionDidTerminate(_ session: MaxWebSession)
    func webSessionDidFail(_ session: MaxWebSession, error: String)
}

struct MonitorProbe: Sendable {
    let installed: Bool
    let bootstrap: Bool
    let hasBridge: Bool
    let href: String
    let readyState: String
    let installError: String?
    let installStep: String?
    let bundleScriptLoaded: Bool

    var summary: String {
        "href=\(href) ready=\(readyState) bootstrap=\(bootstrap) installed=\(installed) bridge=\(hasBridge) bundle=\(bundleScriptLoaded) step=\(installStep ?? "-") error=\(installError ?? "-")"
    }
}

struct NativePingStats: Sendable {
    let lastPacketAt: Int
    let lastMessageAt: Int
    let packetCount: Int
    let messageCount: Int
    let sessionReady: Bool
    let everSynced: Bool
    let now: Int
}

struct MaxSendTextResult: Sendable {
    let ok: Bool
    let cid: Int64?
    let seq: Int?
    let error: String?
}

@MainActor
final class MaxWebSession: NSObject {
    static let maxURL = URL(string: "https://web.max.ru")!
    static let bridgeName = "maxBridge"

    let accountId: UUID
    private(set) var webView: WKWebView!
    private var scriptHandler: ScriptMessageProxy?
    weak var delegate: MaxWebSessionDelegate?

    init(accountId: UUID) {
        self.accountId = accountId
        super.init()
        self.scriptHandler = ScriptMessageProxy(session: self)
        self.webView = makeMonitoringWebView()
        if !WebViewConfigurationFactory.monitorScriptLoaded {
            LogService.shared.log(
                .error,
                accountId: accountId,
                message: "max-monitor.js missing from app bundle",
                level: "ERROR"
            )
        }
    }

    func load() {
        let request = URLRequest(
            url: Self.maxURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        webView.load(request)
    }

    func reload() {
        hardReload()
    }

    func hardReload() {
        load()
    }

    func rebuildWebView() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        scriptHandler = ScriptMessageProxy(session: self)
        webView = makeMonitoringWebView()
        HiddenWebViewHost.attach(webView: webView, accountId: accountId)
        load()
        LogService.shared.log(.reconnect, accountId: accountId, message: "Monitoring WebView rebuilt")
    }

    func fetchAuthUserId() async -> String? {
        let script = """
        (function() {
            try {
                const authRaw = localStorage.getItem('__oneme_auth');
                if (!authRaw) return null;
                const auth = JSON.parse(authRaw);
                const id = (auth.profile && (auth.profile.id || auth.profile.userId))
                    || auth.userId || auth.id || (auth.user && auth.user.id)
                    || auth.viewerId || auth.accountId;
                return id != null && id !== '' ? String(id) : null;
            } catch (e) {
                return null;
            }
        })()
        """
        guard let value = try? await webView.evaluateJavaScript(script) else { return nil }
        if value is NSNull { return nil }
        return MessageMonitorParser.string(from: value)
    }

    func checkAuthentication() async -> Bool {
        let script = "localStorage.getItem('__oneme_auth') != null"
        do {
            let value = try await webView.evaluateJavaScript(script)
            return (value as? Bool) == true
        } catch {
            return false
        }
    }

    func isMonitorAlive() async -> Bool {
        let probe = await probeMonitor()
        return probe.installed
    }

    func probeMonitor() async -> MonitorProbe {
        let script = """
        (function() {
            try {
                return {
                    installed: window.__max2iMessageInstalled === true,
                    bootstrap: window.__max2iMessageBootstrap === true,
                    hasBridge: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.bridgeName)),
                    href: String(location.href || ''),
                    readyState: String(document.readyState || ''),
                    installError: window.__max2iMessageInstallError ? String(window.__max2iMessageInstallError) : null,
                    installStep: window.__max2iMessageInstallStep ? String(window.__max2iMessageInstallStep) : null
                };
            } catch (e) {
                return {
                    installed: false,
                    bootstrap: false,
                    hasBridge: false,
                    href: '',
                    readyState: 'error',
                    installError: String(e && e.message ? e.message : e),
                    installStep: null
                };
            }
        })()
        """
        do {
            guard let value = try await webView.evaluateJavaScript(script) as? [String: Any] else {
                return MonitorProbe(
                    installed: false,
                    bootstrap: false,
                    hasBridge: false,
                    href: webView.url?.absoluteString ?? "",
                    readyState: "nil",
                    installError: "probe returned nil",
                    installStep: nil,
                    bundleScriptLoaded: WebViewConfigurationFactory.monitorScriptLoaded
                )
            }
            return MonitorProbe(
                installed: value["installed"] as? Bool ?? false,
                bootstrap: value["bootstrap"] as? Bool ?? false,
                hasBridge: value["hasBridge"] as? Bool ?? false,
                href: value["href"] as? String ?? "",
                readyState: value["readyState"] as? String ?? "",
                installError: value["installError"] as? String,
                installStep: value["installStep"] as? String,
                bundleScriptLoaded: WebViewConfigurationFactory.monitorScriptLoaded
            )
        } catch {
            return MonitorProbe(
                installed: false,
                bootstrap: false,
                hasBridge: false,
                href: webView.url?.absoluteString ?? "",
                readyState: "eval_error",
                installError: error.localizedDescription,
                installStep: nil,
                bundleScriptLoaded: WebViewConfigurationFactory.monitorScriptLoaded
            )
        }
    }

    @discardableResult
    func ensureMonitorInstalled() async -> Bool {
        let probe = await probeMonitor()
        if probe.installed { return true }

        guard isMaxPage(probe.href) || isMaxPage(webView.url?.absoluteString ?? "") else {
            return false
        }

        if probe.bootstrap && !probe.installed {
            LogService.shared.log(
                .error,
                accountId: accountId,
                message: "Monitor user script failed: \(probe.summary)",
                level: "ERROR"
            )
        }
        return false
    }

    func nudgeMonitor() async {
        let script = """
        (function() {
            if (typeof window.__max2iMessageInstalled !== 'boolean') return false;
            try {
                Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; }, configurable: true });
                Object.defineProperty(document, 'hidden', { get: function() { return false; }, configurable: true });
            } catch (_) {}
            return true;
        })()
        """
        _ = try? await webView.evaluateJavaScript(script)
    }

    func syncMonitorOptions(verboseLogging: Bool, muteProbeLogging: Bool) async {
        let script = """
        window.__max2iMessageVerboseLogging = \(verboseLogging ? "true" : "false");
        window.__max2iMessageMuteProbeLogging = \(muteProbeLogging ? "true" : "false");
        if (\(muteProbeLogging ? "true" : "false") && typeof window.__max2iMessageRunMuteProbeScan === 'function') {
            window.__max2iMessageRunMuteProbeScan('options_enabled');
        }
        """
        _ = try? await webView.evaluateJavaScript(script)
    }

    func sendText(chatId: String, text: String) async -> MaxSendTextResult {
        let chatIdJSON = Self.jsonEncodedLiteral(chatId)
        let textJSON = Self.jsonEncodedLiteral(text)
        let script = """
        (function() {
            if (typeof window.__max2iMessageSendText !== 'function') {
                return { ok: false, error: 'send_not_available' };
            }
            return window.__max2iMessageSendText(\(chatIdJSON), \(textJSON));
        })()
        """
        do {
            guard let value = try await webView.evaluateJavaScript(script) as? [String: Any] else {
                return MaxSendTextResult(ok: false, cid: nil, seq: nil, error: "empty_result")
            }
            let ok = value["ok"] as? Bool ?? false
            let cid = MessageMonitorParser.int64(from: value["cid"])
            let seq = MessageMonitorParser.int64(from: value["seq"]).map { Int($0) }
            let error = MessageMonitorParser.string(from: value["error"])
            return MaxSendTextResult(ok: ok, cid: cid, seq: seq, error: error)
        } catch {
            return MaxSendTextResult(ok: false, cid: nil, seq: nil, error: error.localizedDescription)
        }
    }

    func nativePingMonitor() async -> NativePingStats? {
        let script = """
        (function() {
            if (typeof window.__max2iMessageNativePing === 'function') {
                return window.__max2iMessageNativePing();
            }
            return null;
        })()
        """
        guard let value = try? await webView.evaluateJavaScript(script) as? [String: Any] else {
            return nil
        }
        return NativePingStats(
            lastPacketAt: value["lastPacketAt"] as? Int ?? 0,
            lastMessageAt: value["lastMessageAt"] as? Int ?? 0,
            packetCount: value["packetCount"] as? Int ?? 0,
            messageCount: value["messageCount"] as? Int ?? 0,
            sessionReady: value["sessionReady"] as? Bool ?? false,
            everSynced: value["everSynced"] as? Bool ?? false,
            now: value["now"] as? Int ?? Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    private func isMaxPage(_ href: String) -> Bool {
        href.contains("max.ru")
    }

    private static func jsonEncodedLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private func makeMonitoringWebView() -> WKWebView {
        let proxy = scriptHandler!
        let config = WebViewConfigurationFactory.makeMonitoringConfiguration(
            accountId: accountId,
            scriptHandler: proxy
        )
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.navigationDelegate = self
        WebViewConfigurationFactory.applyDefaults(to: view)
        return view
    }

    fileprivate func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let event = MessageMonitorParser.parse(body: dict) else { return }
        delegate?.webSession(self, didReceive: event)

        switch event.type {
        case .authReady, .authCheck:
            let hasToken = (event.payload["hasToken"] as? Bool)
                ?? (event.payload["userId"] != nil)
            delegate?.webSession(self, didChangeAuth: hasToken)
        default:
            break
        }
    }
}

extension MaxWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url?.absoluteString ?? ""
            guard self.isMaxPage(url) else { return }

            for delay in [0.5, 1.0, 2.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                if await self.ensureMonitorInstalled() { break }
            }

            self.delegate?.webSessionDidFinishNavigation(self)
            let authenticated = await self.checkAuthentication()
            self.delegate?.webSession(self, didChangeAuth: authenticated)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.delegate?.webSessionDidTerminate(self)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.delegate?.webSessionDidFail(self, error: error.localizedDescription)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.delegate?.webSessionDidFail(self, error: error.localizedDescription)
        }
    }
}

private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var session: MaxWebSession?

    init(session: MaxWebSession) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MaxWebSession.bridgeName else { return }
        Task { @MainActor in
            self.session?.handleBridgeMessage(message.body)
        }
    }
}
