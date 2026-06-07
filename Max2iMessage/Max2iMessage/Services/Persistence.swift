import Foundation

final class Persistence: Sendable {
    static let shared = Persistence()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        AppPaths.ensureDirectories()
    }

    func loadAccounts() -> [Account] {
        guard let data = try? Data(contentsOf: AppPaths.accountsFile),
              let accounts = try? decoder.decode([Account].self, from: data),
              !accounts.isEmpty else {
            return [Account.makeDefault()]
        }
        return accounts
    }

    func saveAccounts(_ accounts: [Account]) {
        guard let data = try? encoder.encode(accounts) else { return }
        try? data.write(to: AppPaths.accountsFile, options: .atomic)
    }

    func loadDailyStatsByAccount() -> [UUID: DailyStats] {
        guard let data = try? Data(contentsOf: AppPaths.dailyStatsFile()),
              let raw = try? decoder.decode([String: DailyStats].self, from: data) else {
            return [:]
        }
        var result: [UUID: DailyStats] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                result[id] = value
            }
        }
        return result
    }

    func saveDailyStatsByAccount(_ stats: [UUID: DailyStats]) {
        let raw = Dictionary(uniqueKeysWithValues: stats.map { ($0.key.uuidString, $0.value) })
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: AppPaths.dailyStatsFile(), options: .atomic)
    }

    func loadPreferences() -> AppPreferences {
        guard let data = try? Data(contentsOf: AppPaths.preferencesFile),
              let preferences = try? decoder.decode(AppPreferences.self, from: data) else {
            return .default
        }
        return preferences
    }

    func savePreferences(_ preferences: AppPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        try? data.write(to: AppPaths.preferencesFile, options: .atomic)
    }
}
