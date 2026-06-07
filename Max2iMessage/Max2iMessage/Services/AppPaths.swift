import Foundation

enum AppPaths {
    static let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("Max2iMessage", isDirectory: true)

    static let logs = FileManager.default.urls(
        for: .libraryDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("Logs/Max2iMessage", isDirectory: true)

    static var accountsFile: URL {
        appSupport.appendingPathComponent("accounts.json")
    }

    static var preferencesFile: URL {
        appSupport.appendingPathComponent("preferences.json")
    }

    static func dedupFile(accountId: UUID) -> URL {
        appSupport
            .appendingPathComponent("dedup", isDirectory: true)
            .appendingPathComponent("\(accountId.uuidString).json")
    }

    static var globalForwardDedupFile: URL {
        appSupport.appendingPathComponent("global-forward-dedup.json")
    }

    static func dailyStatsFile(date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: date)
        return appSupport
            .appendingPathComponent("stats", isDirectory: true)
            .appendingPathComponent("\(key)-accounts.json")
    }

    static var logFile: URL {
        logs.appendingPathComponent("app.log")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for url in [appSupport, logs, appSupport.appendingPathComponent("dedup"),
                    appSupport.appendingPathComponent("stats")] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
