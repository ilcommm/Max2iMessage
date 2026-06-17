import Foundation

struct IndexedBubbleTarget: Sendable {
    let accountId: UUID
    let target: LastReplyTarget
}

@MainActor
final class LastReplyStore {
    private var targets: [UUID: LastReplyTarget] = [:]
    private var bubblesByGuid: [String: IndexedBubbleTarget] = [:]
    private var bubblesByBody: [String: IndexedBubbleTarget] = [:]
    private var bubbleGuidOrder: [String] = []
    private var recentOutboundTexts: [UUID: [String]] = [:]
    private let maxRecentOutboundTexts = 20
    private let maxIndexedBubbles = 50

    func setTarget(accountId: UUID, target: LastReplyTarget) {
        targets[accountId] = target
    }

    func target(for accountId: UUID) -> LastReplyTarget? {
        targets[accountId]
    }

    func clearTarget(accountId: UUID) {
        targets.removeValue(forKey: accountId)
    }

    func registerBubble(accountId: UUID, iMessageGuid: String, target: LastReplyTarget) {
        let normalizedGuid = IMessagesDatabaseMonitor.normalizeMessageGuid(iMessageGuid)
        guard !normalizedGuid.isEmpty else { return }

        let entry = IndexedBubbleTarget(accountId: accountId, target: target)
        bubblesByGuid[normalizedGuid] = entry
        bubbleGuidOrder.removeAll { $0 == normalizedGuid }
        bubbleGuidOrder.append(normalizedGuid)

        while bubbleGuidOrder.count > maxIndexedBubbles {
            let removed = bubbleGuidOrder.removeFirst()
            bubblesByGuid.removeValue(forKey: removed)
        }
    }

    func registerBubbleBody(accountId: UUID, body: String, target: LastReplyTarget) {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else { return }
        bubblesByBody[normalizedBody] = IndexedBubbleTarget(accountId: accountId, target: target)
        while bubblesByBody.count > maxIndexedBubbles {
            if let key = bubblesByBody.keys.first {
                bubblesByBody.removeValue(forKey: key)
            }
        }
    }

    func target(forBubbleGuid guid: String) -> IndexedBubbleTarget? {
        let normalizedGuid = IMessagesDatabaseMonitor.normalizeMessageGuid(guid)
        guard !normalizedGuid.isEmpty else { return nil }
        return bubblesByGuid[normalizedGuid]
    }

    func target(forBubbleBody body: String) -> IndexedBubbleTarget? {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else { return nil }
        return bubblesByBody[normalizedBody]
    }

    func pruneExpiredBubbles(windowMinutes: Double, now: Date = .now) {
        guard windowMinutes > 0 else { return }
        let cutoff = now.addingTimeInterval(-windowMinutes * 60)
        var kept: [String] = []
        for guid in bubbleGuidOrder {
            guard let entry = bubblesByGuid[guid] else { continue }
            if entry.target.forwardedAt >= cutoff {
                kept.append(guid)
            } else {
                bubblesByGuid.removeValue(forKey: guid)
            }
        }
        bubbleGuidOrder = kept

        let bodyCutoff = cutoff
        bubblesByBody = bubblesByBody.filter { _, entry in
            entry.target.forwardedAt >= bodyCutoff
        }
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

    func matchesRecentOutbound(accountId: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let list = recentOutboundTexts[accountId] else { return false }
        for outbound in list {
            if outbound == trimmed { return true }
            if trimmed.count >= 8, outbound.contains(trimmed) { return true }
            if outbound.count >= 8, trimmed.contains(outbound) { return true }
        }
        return false
    }
}
