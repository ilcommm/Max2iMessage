import Foundation
import SwiftUI

@MainActor
@Observable
final class AppState {
    let accountManager = AccountManager()
    var selectedAccountId: UUID?
    var launchAtLogin = LaunchAtLoginService.isEnabled
    private var didBootstrap = false

    init() {
        bootstrapIfNeeded()
    }

    var selectedAccount: Account? {
        guard let selectedAccountId else { return accountManager.accounts.first }
        return accountManager.account(for: selectedAccountId)
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        AppPaths.ensureDirectories()
        LogService.shared.log(.appStart, message: "Max2iMessage started, log=\(AppPaths.logFile.path)")
        accountManager.bootstrap()
        selectedAccountId = accountManager.accounts.first?.id
        launchAtLogin = LaunchAtLoginService.isEnabled
    }

    func selectAccount(_ id: UUID) {
        selectedAccountId = id
    }

    @discardableResult
    func addAccount() -> Account {
        let account = accountManager.addAccount()
        selectedAccountId = account.id
        return account
    }

    func removeSelectedAccount() {
        guard let id = selectedAccountId else { return }
        accountManager.removeAccount(id)
        selectedAccountId = accountManager.accounts.first?.id
    }

    func shutdown() {
        accountManager.shutdown()
    }

    func openLogs() {
        LogService.shared.openLogFile()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginService.isEnabled
        } catch {
            LogService.shared.log(.error, message: "Launch at login failed: \(error.localizedDescription)", level: "ERROR")
        }
    }
}
