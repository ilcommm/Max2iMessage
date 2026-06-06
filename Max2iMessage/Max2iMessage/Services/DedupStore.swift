import Foundation

final class DedupStore: @unchecked Sendable {
    private let accountId: UUID
    private var keys: [String] = []
    private var keySet: Set<String> = []
    private let maxKeys = 10_000
    private let queue = DispatchQueue(label: "ilcomm.Max2iMessage.dedup")
    private var saveWorkItem: DispatchWorkItem?

    init(accountId: UUID) {
        self.accountId = accountId
        load()
    }

    func contains(_ key: String) -> Bool {
        queue.sync { keySet.contains(key) }
    }

    func markProcessed(accountId: UUID, message: MaxMessage) -> Bool {
        let fullKey = "\(accountId.uuidString):\(message.dedupeKey)"
        return queue.sync {
            guard !keySet.contains(fullKey) else { return false }
            keys.append(fullKey)
            keySet.insert(fullKey)
            if keys.count > maxKeys {
                let excess = keys.count - maxKeys
                let removedKeys = keys.prefix(excess)
                keys.removeFirst(excess)
                for key in removedKeys {
                    keySet.remove(key)
                }
            }
            scheduleSave()
            return true
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func load() {
        let url = AppPaths.dedupFile(accountId: accountId)
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([String].self, from: data) else { return }
        keys = loaded
        keySet = Set(loaded)
    }

    private func save() {
        let snapshot = keys
        let url = AppPaths.dedupFile(accountId: accountId)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
