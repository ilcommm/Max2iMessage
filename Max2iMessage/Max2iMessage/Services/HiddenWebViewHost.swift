import AppKit
import WebKit

@MainActor
enum HiddenWebViewHost {
    private static var windows: [UUID: NSWindow] = [:]
    private static var keepAliveActivity: NSObjectProtocol?

    static func attach(webView: WKWebView, accountId: UUID) {
        if keepAliveActivity == nil {
            keepAliveActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Max2iMessage MAX monitoring"
            )
        }
        webView.removeFromSuperview()

        if let existing = windows[accountId] {
            existing.contentView = nil
            existing.close()
        }

        let size = NSSize(width: 320, height: 240)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let origin: NSPoint
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            origin = NSPoint(
                x: frame.maxX - size.width - 8,
                y: frame.minY + 8
            )
        } else {
            origin = NSPoint(x: 100, y: 100)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = container
        window.orderFrontRegardless()

        windows[accountId] = window
    }

    static func detach(accountId: UUID) {
        if let window = windows[accountId] {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.contentView = nil
            window.close()
        }
        windows[accountId] = nil

        if windows.isEmpty, let keepAliveActivity {
            ProcessInfo.processInfo.endActivity(keepAliveActivity)
            self.keepAliveActivity = nil
        }
    }
}
