import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Max2iMessage")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            accountsSection
            Divider()
            statsSection
            Divider()
            actionsSection
        }
        .frame(width: 280)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(appState.accountManager.snapshots) { snapshot in
                Button {
                    appState.selectAccount(snapshot.account.id)
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 6) {
                        Text(snapshot.status.indicator)
                            .foregroundStyle(statusColor(snapshot.status))
                        Text(snapshot.account.name)
                        Spacer()
                        Text(snapshot.status.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 8)
    }

    private var statsSection: some View {
        let stats = appState.accountManager.aggregatedDailyStats
        return VStack(alignment: .leading, spacing: 4) {
            Text("Сегодня (все аккаунты):")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Отфильтровано: \(stats.filtered)")
            Text("Получено: \(stats.received)")
            Text("Отправлено: \(stats.sent)")
            Text("Ошибок: \(stats.errors)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical,  8)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Настройки") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            if appState.accountManager.accounts.count == 1 {
                Button("Войти в MAX") {
                    openWindow(id: "auth")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                Menu("Войти в MAX") {
                    ForEach(appState.accountManager.accounts) { account in
                        Button(account.name) {
                            appState.selectAccount(account.id)
                            openWindow(id: "auth")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }

            Button("Добавить аккаунт…") {
                appState.addAccount()
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Переподключить MAX") {
                appState.accountManager.reloadAllAccounts()
            }

            Button("Открыть логи") {
                appState.openLogs()
            }

            Divider()
                .padding(.vertical, 4)

            Button("Выход") {
                appState.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusColor(_ status: AccountStatus) -> Color {
        switch status {
        case .online: .green
        case .reconnecting: .orange
        case .needsAuth: .yellow
        case .offline: .secondary
        }
    }
}
