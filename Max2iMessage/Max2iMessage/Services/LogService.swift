import AppKit
import Foundation
import os

enum LogEvent: String {
    case appStart = "app_start"
    case appStop = "app_stop"
    case error = "error"
    case authSuccess = "auth_success"
    case authLost = "auth_lost"
    case messageDetected = "message_detected"
    case messageSent = "message_sent"
    case sendFailed = "send_failed"
    case replyDetected = "reply_detected"
    case replySent = "reply_sent"
    case replyFailed = "reply_failed"
    case reconnect = "reconnect"
    case chatRaw = "chat_raw"
    case pipelineTrace = "pipeline_trace"
    case muteProbe = "mute_probe"
}

final class LogService: @unchecked Sendable {
    static let shared = LogService()

    private let queue = DispatchQueue(label: "ilcomm.Max2iMessage.logging")
    private let maxLogSize: UInt64 = 5 * 1024 * 1024
    private let logger = Logger(subsystem: "ilcomm.Max2iMessage", category: "app")

    private init() {
        AppPaths.ensureDirectories()
    }

    func logChatRaw(accountId: UUID?, payload: [String: Any]) {
        let json = BridgeJSON.string(payload) ?? String(describing: payload)
        log(.chatRaw, accountId: accountId, message: json)
    }

    func logMuteProbe(accountId: UUID?, payload: [String: Any]) {
        let json = BridgeJSON.string(payload) ?? String(describing: payload)
        log(.muteProbe, accountId: accountId, message: json)
    }

    func log(_ event: LogEvent, accountId: UUID? = nil, message: String, level: String = "INFO") {
        guard !PrivacySettings.isActive else { return }
        let accountPart = accountId.map { " account=\($0.uuidString)" } ?? ""
        let line = "\(isoTimestamp()) [\(level)] event=\(event.rawValue)\(accountPart) \(message)\n"
        queue.async { [self] in
            self.write(line)
        }
        logger.log("\(event.rawValue, privacy: .public)\(accountPart, privacy: .public) \(message, privacy: .public)")
    }

    func openLogFile() {
        guard !PrivacySettings.isActive else { return }
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    var isLoggingEnabled: Bool {
        !PrivacySettings.isActive
    }

    private func write(_ line: String) {
        rotateIfNeeded()
        let url = AppPaths.logFile
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func rotateIfNeeded() {
        let url = AppPaths.logFile
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let backup = AppPaths.logs.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
