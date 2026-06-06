import AppKit
import Foundation

enum MessageForwarderError: LocalizedError {
    case emptyRecipient
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyRecipient: "Не указан получатель iMessage"
        case .appleScriptFailed(let detail): "Ошибка AppleScript: \(detail)"
        }
    }
}

struct MessageForwarder: Sendable {
    func formatMessage(senderName: String, text: String) -> String {
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        return "\(name): \(text)"
    }

    func send(to recipient: String, text: String) throws {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageForwarderError.emptyRecipient }

        let escapedRecipient = escapeAppleScript(trimmed)
        let escapedText = escapeAppleScript(text)

        let script = """
        tell application "Messages"
            activate
            set iMessageService to first service whose service type is iMessage
            set targetRecipient to participant "\(escapedRecipient)" of iMessageService
            send "\(escapedText)" to targetRecipient
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw MessageForwarderError.appleScriptFailed("не удалось создать скрипт")
        }

        appleScript.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            throw MessageForwarderError.appleScriptFailed("[\(number)] \(message)")
        }
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
