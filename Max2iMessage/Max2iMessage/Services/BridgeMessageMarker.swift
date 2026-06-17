import Foundation

/// Invisible prefix for outbound iMessage bodies from Max2iMessage.
/// Messages with this prefix are ignored when detecting user replies.
enum BridgeMessageMarker {
    // WORD JOINER + ZWNJ + WORD JOINER — invisible in iMessage UI.
    static let prefix = "\u{2060}\u{200C}\u{2060}"

    static func mark(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if isMarked(trimmed) { return trimmed }
        return prefix + trimmed
    }

    static func strip(_ text: String) -> String {
        var value = text
        if value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isMarked(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    static var prefixUTF8Data: Data {
        Data(prefix.utf8)
    }
}
