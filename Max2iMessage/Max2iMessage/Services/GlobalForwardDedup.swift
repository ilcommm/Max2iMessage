import Foundation

/// Prevents the same MAX message from being forwarded to iMessage more than once
/// when several app accounts monitor the same MAX login.
final class GlobalForwardDedup: @unchecked Sendable {
    static let shared = GlobalForwardDedup()

    private var keys: [String] = []
    private var keySet: Set<String> = []
    private let maxKeys = 20_000
    private let queue = DispatchQueue(label: "ilcomm.Max2iMessage.globalForwardDedup")
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
    }

    func tryClaim(key: String) -> Bool {
        queue.sync {
            guard !keySet.contains(key) else { return false }
            keys.append(key)
            keySet.insert(key)
            if keys.count > maxKeys {
                let excess = keys.count - maxKeys
                let removedKeys = keys.prefix(excess)
                keys.removeFirst(excess)
                for removed in removedKeys {
                    keySet.remove(removed)
                }
            }
            scheduleSave()
            return true
        }
    }

    static func makeKey(maxUserId: String?, accountId: UUID, message: MaxMessage) -> String {
        if let maxUserId, !maxUserId.isEmpty {
            return "\(maxUserId):\(message.dedupeKey)"
        }
        // Different MAX logins while userId is still loading: don't block each other.
        return "\(accountId.uuidString):\(message.dedupeKey)"
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func load() {
        let url = AppPaths.globalForwardDedupFile
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([String].self, from: data) else { return }
        keys = loaded
        keySet = Set(loaded)
    }

    private func save() {
        let snapshot = keys
        let url = AppPaths.globalForwardDedupFile
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
