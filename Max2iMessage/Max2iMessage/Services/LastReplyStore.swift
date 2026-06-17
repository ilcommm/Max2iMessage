import Foundation

@MainActor
final class LastReplyStore {
    private var targets: [UUID: LastReplyTarget] = [:]
    private var recentOutboundTexts: [UUID: [String]] = [:]
    private let maxRecentOutboundTexts = 20

    func setTarget(accountId: UUID, target: LastReplyTarget) {
        targets[accountId] = target
    }

    func target(for accountId: UUID) -> LastReplyTarget? {
        targets[accountId]
    }

    func clearTarget(accountId: UUID) {
        targets.removeValue(forKey: accountId)
    }

    func noteOutboundText(accountId: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentOutboundTexts[accountId] ?? []
        list.append(trimmed)
        if list.count > maxRecentOutboundTexts {
            list.removeFirst(list.count - maxRecentOutboundTexts)
        }
        recentOutboundTexts[accountId] = list
    }

    func wasRecentlySentToIMessage(accountId: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return recentOutboundTexts[accountId]?.contains(trimmed) == true
    }
}
