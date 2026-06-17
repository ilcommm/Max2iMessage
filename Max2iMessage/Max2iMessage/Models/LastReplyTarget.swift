import Foundation

struct LastReplyTarget: Codable, Equatable, Sendable {
    var chatId: String
    var senderName: String
    var messageId: String
    var forwardedAt: Date

    func isExpired(windowMinutes: Double, now: Date = .now) -> Bool {
        guard windowMinutes > 0 else { return false }
        return now.timeIntervalSince(forwardedAt) > windowMinutes * 60
    }
}
