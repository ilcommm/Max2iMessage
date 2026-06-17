import Foundation
import WebKit

@MainActor
@Observable
final class AccountManager {
    private(set) var accounts: [Account] = []
    private(set) var statuses: [UUID: AccountStatus] = [:]
    private(set) var dailyStatsByAccount: [UUID: DailyStats] = [:]
    private(set) var maxUserIdsByAccount: [UUID: String] = [:]
    private(set) var replyStatuses: [UUID: String] = [:]
    private(set) var iMessageDatabaseAccess = false
    private(set) var iMessageDatabaseStatus: String?
    private var runtimes: [UUID: AccountRuntime] = [:]
    private let lastReplyStore = LastReplyStore()

    var duplicateMaxUserIdWarning: String? {
        var byUserId: [String: [Account]] = [:]
        for account in accounts where account.enabled {
            guard let userId = maxUserIdsByAccount[account.id] else { continue }
            byUserId[userId, default: []].append(account)
        }
        for (_, grouped) in byUserId where grouped.count > 1 {
            let names = grouped.map(\.name).joined(separator: ", ")
            return "Аккаунты «\(names)» используют один MAX (совпадает userId). У дополнительных мониторинг отключён."
        }
        return nil
    }

    func monitoringNote(for accountId: UUID) -> String? {
        runtimes[accountId]?.monitoringPauseReason
    }

    var aggregatedDailyStats: DailyStats {
        dailyStatsByAccount.values.reduce(into: DailyStats()) { result, stats in
            result.filtered += stats.filtered
            result.received += stats.received
            result.sent += stats.sent
            result.replies += stats.replies
            result.errors += stats.errors
        }
    }

    var snapshots: [AccountSnapshot] {
        accounts.map { account in
            AccountSnapshot(
                account: account,
                status: statuses[account.id] ?? .offline,
                stats: dailyStatsByAccount[account.id] ?? DailyStats(),
                replyStatus: replyStatuses[account.id]
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
        reconcileMonitoring()
        startReplyMonitoringIfNeeded()
    }

    private func startReplyMonitoringIfNeeded() {
        let monitor = IMessagesDatabaseMonitor.shared
        monitor.onInboundMessage = { [weak self] accountId, message in
            Task { @MainActor in
                self?.dispatchInboundIMessage(message, triggeredAccountId: accountId)
            }
        }
        monitor.start()
        refreshReplyMonitoring()
        refreshIMessageDatabaseAccess()
    }

    private func dispatchInboundIMessage(_ message: InboundIMessage, triggeredAccountId: UUID) {
        guard let triggeredAccount = account(for: triggeredAccountId) else { return }
        let recipient = triggeredAccount.effectiveRecipient

        let candidates = accounts.filter { account in
            account.supportsIMessageReply
                && IMessagesDatabaseMonitor.handlesMatch(account.effectiveRecipient, recipient)
        }

        let activeCandidates = candidates.filter { account in
            guard let target = lastReplyStore.target(for: account.id) else { return false }
            return !target.isExpired(windowMinutes: account.replyWindowMinutes)
        }

        let selected = activeCandidates.max(by: {
            let left = lastReplyStore.target(for: $0.id)?.forwardedAt ?? .distantPast
            let right = lastReplyStore.target(for: $1.id)?.forwardedAt ?? .distantPast
            return left < right
        }) ?? candidates.first(where: { $0.id == triggeredAccountId }) ?? candidates.first

        guard let accountId = selected?.id else { return }
        runtimes[accountId]?.handleInboundIMessage(message)
    }

    func refreshIMessageDatabaseAccess() {
        IMessagesDatabaseMonitor.shared.refreshAccess(waitUntilDone: true)
        iMessageDatabaseAccess = IMessagesDatabaseMonitor.shared.hasDatabaseAccess
        if iMessageDatabaseAccess {
            iMessageDatabaseStatus = "Доступ к Messages: есть (\(AppPaths.messagesDatabaseFile.path))"
        } else {
            let detail = IMessagesDatabaseMonitor.shared.lastAccessError
                ?? "Нет доступа к \(AppPaths.messagesDatabaseFile.path)"
            iMessageDatabaseStatus = detail
        }
    }

    private func refreshReplyMonitoring() {
        let monitor = IMessagesDatabaseMonitor.shared
        for account in accounts {
            if account.supportsIMessageReply {
                monitor.register(accountId: account.id, recipient: account.effectiveRecipient)
            } else {
                monitor.unregister(accountId: account.id)
            }
        }
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
        reconcileMonitoring()
        refreshReplyMonitoring()
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
        replyStatuses[accountId] = nil
        dailyStatsByAccount[accountId] = nil
        maxUserIdsByAccount[accountId] = nil
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

    func hasAccountNeedingAuth() -> Bool {
        accounts.contains { shouldOfferAuth(for: $0.id) }
    }

    func shouldOfferAuth(for accountId: UUID) -> Bool {
        if !PrivacySettings.isActive { return true }
        let status = statuses[accountId] ?? .offline
        return status == .needsAuth || status == .offline
    }

    func refreshPrivacySensitiveSettings() {
        for runtime in runtimes.values {
            runtime.refreshMonitorOptions()
        }
    }

    func status(for accountId: UUID) -> AccountStatus {
        statuses[accountId] ?? .offline
    }

    func shutdown() {
        for runtime in runtimes.values {
            runtime.stop()
        }
        IMessagesDatabaseMonitor.shared.stop()
        saveDailyStats()
        LogService.shared.log(.appStop, message: "Application stopped")
    }

    private func startRuntime(for account: Account) {
        let accountId = account.id
        runtimes[accountId]?.stop()
        let runtime = AccountRuntime(
            account: account,
            lastReplyStore: lastReplyStore,
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
        runtime.onMaxUserIdChange = { [weak self] userId in
            self?.noteMaxUserId(accountId: accountId, userId: userId)
        }
        runtime.onReplyStatusChange = { [weak self] message in
            self?.replyStatuses[accountId] = message
        }
        runtimes[accountId] = runtime
        reconcileMonitoring()
        refreshReplyMonitoring()
    }

    private func noteMaxUserId(accountId: UUID, userId: String) {
        let previous = maxUserIdsByAccount[accountId]
        maxUserIdsByAccount[accountId] = userId
        if previous != userId {
            LogService.shared.log(.authSuccess, accountId: accountId, message: "MAX userId=\(userId)")
        }
        reconcileMonitoring()
    }

    private func reconcileMonitoring() {
        let enabled = accounts.filter(\.enabled)

        for account in enabled {
            runtimes[account.id]?.resumeMonitoring()
        }

        var byUserId: [String: [Account]] = [:]
        for account in enabled {
            guard let userId = maxUserIdsByAccount[account.id] else { continue }
            byUserId[userId, default: []].append(account)
        }

        for (_, grouped) in byUserId where grouped.count > 1 {
            guard let primary = grouped.first else { continue }
            for account in grouped.dropFirst() {
                runtimes[account.id]?.suspendMonitoring(
                    reason: "Тот же MAX userId=\(maxUserIdsByAccount[primary.id] ?? "?") что у «\(primary.name)». Войдите в другой MAX или отключите этот app-аккаунт."
                )
            }
        }
    }
}
