import Foundation

struct MaxMessage: Identifiable, Sendable {
    let id: String
    let chatId: String
    let senderId: String
    let senderName: String
    let text: String
    let timestamp: Int64
    let isGroupChat: Bool
    let isMutedChat: Bool
    let chatTypeKnown: Bool
    let chatMuteKnown: Bool
    let hasAttachment: Bool
    let chatTitle: String

    var dedupeKey: String {
        "\(chatId):\(id)"
    }

    var displayText: String {
        if !text.isEmpty { return text }
        if hasAttachment { return "[вложение]" }
        return ""
    }
}
