import Foundation
import WebKit

@MainActor
@Observable
final class AccountManager {
    private(set) var accounts: [Account] = []
    private(set) var statuses: [UUID: AccountStatus] = [:]
    private(set) var dailyStatsByAccount: [UUID: DailyStats] = [:]
    private var runtimes: [UUID: AccountRuntime] = [:]

    var aggregatedDailyStats: DailyStats {
        dailyStatsByAccount.values.reduce(into: DailyStats()) { result, stats in
            result.filtered += stats.filtered
            result.received += stats.received
            result.sent += stats.sent
            result.errors += stats.errors
        }
    }

    var snapshots: [AccountSnapshot] {
        accounts.map { account in
            AccountSnapshot(
                account: account,
                status: statuses[account.id] ?? .offline,
                stats: dailyStatsByAccount[account.id] ?? DailyStats()
            )
        }
    }

    func account(for id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    func bootstrap() {
        accounts = Persistence.shared.loadAccounts()
        dailyStatsByAccount = Persistence.shared.loadDailyStatsByAccount()
        if accounts.isEmpty {
            accounts = [Account.makeDefault()]
            saveAccounts()
        }
        for account in accounts {
            statuses[account.id] = .offline
            if dailyStatsByAccount[account.id] == nil {
                dailyStatsByAccount[account.id] = DailyStats()
            }
            startRuntime(for: account)
        }
        saveDailyStats()
    }

    func saveAccounts() {
        Persistence.shared.saveAccounts(accounts)
    }

    private func saveDailyStats() {
        Persistence.shared.saveDailyStatsByAccount(dailyStatsByAccount)
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        saveAccounts()
        runtimes[account.id]?.updateAccount(account)
    }

    @discardableResult
    func addAccount(name: String? = nil) -> Account {
        let number = accounts.count + 1
        let account = Account(
            id: UUID(),
            name: name ?? "Аккаунт \(number)",
            iMessageRecipient: "",
            contactIdentifier: nil,
            enabled: true,
            skipGroupChats: false,
            skipOwnMessages: true,
            skipMutedChats: true,
            forwardAttachmentsPlaceholder: true
        )
        accounts.append(account)
        statuses[account.id] = .offline
        dailyStatsByAccount[account.id] = DailyStats()
        saveAccounts()
        saveDailyStats()
        startRuntime(for: account)
        LogService.shared.log(.authSuccess, accountId: account.id, message: "Account added: \(account.name)")
        return account
    }

    func removeAccount(_ accountId: UUID) {
        guard accounts.count > 1 else { return }
        runtimes[accountId]?.stop()
        runtimes[accountId] = nil
        accounts.removeAll { $0.id == accountId }
        statuses[accountId] = nil
        dailyStatsByAccount[accountId] = nil
        saveAccounts()
        saveDailyStats()
        LogService.shared.log(.appStop, accountId: accountId, message: "Account removed")
    }

    func reloadAccount(_ accountId: UUID) {
        runtimes[accountId]?.reload()
    }

    func reloadAllAccounts() {
        for account in accounts where account.enabled {
            reloadAccount(account.id)
        }
        LogService.shared.log(.reconnect, message: "Manual reconnect for \(accounts.count) account(s)")
    }

    func webView(for accountId: UUID) -> WKWebView? {
        runtimes[accountId]?.webView
    }

    func shutdown() {
        for runtime in runtimes.values {
            runtime.stop()
        }
        saveDailyStats()
        LogService.shared.log(.appStop, message: "Application stopped")
    }

    private func startRuntime(for account: Account) {
        let accountId = account.id
        let runtime = AccountRuntime(
            account: account,
            statsUpdater: { [weak self] in
                self?.dailyStatsByAccount[accountId] ?? DailyStats()
            },
            statsRecorder: { [weak self] stats in
                guard let self else { return }
                self.dailyStatsByAccount[accountId] = stats
                self.saveDailyStats()
            }
        )
        runtime.onStatusChange = { [weak self] status in
            self?.statuses[accountId] = status
        }
        runtime.onStatsChange = { [weak self] in
            self?.saveDailyStats()
        }
        runtimes[accountId] = runtime
        runtime.start()
    }
}
