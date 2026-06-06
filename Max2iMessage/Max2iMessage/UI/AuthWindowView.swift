import SwiftUI

struct AuthWindowView: View {
    @Environment(AppState.self) private var appState

    private var account: Account? {
        appState.selectedAccount
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

            Text("Войдите в аккаунт MAX в окне ниже. Пароль не сохраняется — только сессия WebKit. Каждый аккаунт хранится отдельно.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                AuthWebView(accountId: account.id) {
                    appState.accountManager.reloadAccount(account.id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Аккаунт не найден", systemImage: "person.crop.circle.badge.exclamationmark")
            }

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
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 560)
    }
}
