import SwiftUI

struct AuthWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    private var account: Account? {
        appState.selectedAccount
    }

    private var accountStatus: AccountStatus {
        guard let account else { return .offline }
        return appState.accountManager.status(for: account.id)
    }

    private var canShowMaxUI: Bool {
        !PrivacySettings.isActive
            || accountStatus == .needsAuth
            || accountStatus == .offline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account {
                Text("Вход в MAX — \(account.name)")
                    .font(.title2)
            } else {
                Text("Вход в MAX")
                    .font(.title2)
            }

            if PrivacySettings.isActive {
                Text("Режим приватности включён: интерфейс MAX доступен только для входа. После авторизации окно закроется автоматически.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Войдите в аккаунт MAX в окне ниже. Пароль не сохраняется — только сессия WebKit. Каждый аккаунт хранится отдельно.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if appState.accountManager.accounts.count > 1 {
                Picker("Аккаунт", selection: Binding(
                    get: { appState.selectedAccountId ?? appState.accountManager.accounts.first!.id },
                    set: { appState.selectAccount($0) }
                )) {
                    ForEach(appState.accountManager.accounts) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
            }

            if let account {
                if canShowMaxUI {
                    AuthWebView(accountId: account.id) {
                        appState.accountManager.reloadAccount(account.id)
                        if PrivacySettings.isActive {
                            dismissWindow(id: "auth")
                        }
                    }
                    .id(account.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ContentUnavailableView(
                        "Сессия активна",
                        systemImage: "lock.fill",
                        description: Text("Интерфейс MAX скрыт в режиме приватности. Переподключение выполняется автоматически в фоне.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Аккаунт не найден", systemImage: "person.crop.circle.badge.exclamationmark")
            }

            if canShowMaxUI {
                HStack {
                    Button("Перезагрузить") {
                        if let account {
                            appState.accountManager.reloadAccount(account.id)
                        }
                    }
                    Spacer()
                    Button("Готово") {
                        if let account {
                            appState.accountManager.reloadAccount(account.id)
                        }
                        dismissWindow(id: "auth")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Закрыть") {
                        dismissWindow(id: "auth")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 560)
    }
}
