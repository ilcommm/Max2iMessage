import AppKit
import Foundation

enum MessageForwarderError: LocalizedError {
    case emptyRecipient(String)
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyRecipient(let channel): "Не указан получатель (\(channel))"
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

    func formatNotificationOnly(senderName: String) -> String {
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Новое сообщение в MAX" }
        return "\(name) написал(а) в MAX"
    }

    func formatEmailSubject(senderName: String) -> String {
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Новое сообщение в MAX" }
        return "MAX: \(name)"
    }

    func sendiMessage(to recipient: String, text: String) throws {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageForwarderError.emptyRecipient("iMessage") }

        let escapedRecipient = escapeAppleScript(trimmed)
        let escapedText = escapeAppleScript(text)

        let script = """
        tell application "Messages"
            set iMessageService to first service whose service type is iMessage
            set targetRecipient to participant "\(escapedRecipient)" of iMessageService
            send "\(escapedText)" to targetRecipient
        end tell
        """

        try runAppleScript(script)
    }

    func sendEmail(to recipient: String, subject: String, text: String) throws {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageForwarderError.emptyRecipient("Email") }

        let escapedRecipient = escapeAppleScript(trimmed)
        let escapedSubject = escapeAppleScript(subject)
        let escapedText = escapeAppleScript(text)

        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedText)", visible:false}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"\(escapedRecipient)"}
            end tell
            send newMessage
        end tell
        """

        try runAppleScript(script)
    }

    private func runAppleScript(_ script: String) throws {
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
