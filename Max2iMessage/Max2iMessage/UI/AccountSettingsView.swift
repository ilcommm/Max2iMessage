import SwiftUI

struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var draftAccount = Account.makeDefault()
    @State private var saveStatus: String?

    private var showDiagnostics: Bool {
        !PrivacySettings.isActive
    }

    private var showAuthButton: Bool {
        appState.accountManager.shouldOfferAuth(for: draftAccount.id)
    }

    var body: some View {
        NavigationSplitView {
            accountsList
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            accountDetail
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { syncDraftFromSelection() }
        .onChange(of: appState.selectedAccountId) { syncDraftFromSelection() }
        .onChange(of: appState.accountManager.accounts) { syncDraftFromSelection() }
    }

    private var accountsList: some View {
        List(selection: Binding(
            get: { appState.selectedAccountId },
            set: { newValue in
                if let newValue { appState.selectAccount(newValue) }
            }
        )) {
            Section("Аккаунты MAX") {
                ForEach(appState.accountManager.accounts) { account in
                    let status = appState.accountManager.statuses[account.id] ?? .offline
                    HStack {
                        Text(status.indicator)
                            .foregroundStyle(statusColor(status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            if account.hasConfiguredDestination {
                                Text(account.destinationSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(account.id as UUID?)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.addAccount()
                    syncDraftFromSelection()
                } label: {
                    Label("Добавить", systemImage: "plus")
                }

                if appState.accountManager.accounts.count > 1 {
                    Button {
                        appState.removeSelectedAccount()
                        syncDraftFromSelection()
                    } label: {
                        Label("Удалить", systemImage: "minus")
                    }
                }
            }
        }
    }

    private var accountDetail: some View {
        Form {
            Section("Аккаунт MAX") {
                if let warning = appState.accountManager.duplicateMaxUserIdWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let note = appState.accountManager.monitoringNote(for: draftAccount.id) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Название", text: $draftAccount.name)
                    .onChange(of: draftAccount.name) { persistAccount() }
                Toggle("Включён", isOn: $draftAccount.enabled)
                    .onChange(of: draftAccount.enabled) { persistAccount() }
            }

            Section("Пересылка") {
                Picker("Канал", selection: $draftAccount.forwardDestination) {
                    ForEach(ForwardDestination.allCases, id: \.self) { destination in
                        Text(destination.label).tag(destination)
                    }
                }
                .onChange(of: draftAccount.forwardDestination) { persistAccount() }

                if draftAccount.forwardDestination == .iMessage || draftAccount.forwardDestination == .both {
                    Text("Укажите телефон или Apple ID того, кто будет получать уведомления на iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Телефон или Apple ID email", text: $draftAccount.iMessageRecipient)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draftAccount.iMessageRecipient) { persistAccount() }
                    ContactPickerButton(
                        recipient: $draftAccount.iMessageRecipient,
                        contactIdentifier: $draftAccount.contactIdentifier
                    )
                    .onChange(of: draftAccount.iMessageRecipient) { persistAccount() }
                }

                if draftAccount.forwardDestination == .email || draftAccount.forwardDestination == .both {
                    Text("Укажите email получателя — письмо отправится через приложение Mail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Email", text: $draftAccount.emailRecipient)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draftAccount.emailRecipient) { persistAccount() }
                    ContactPickerButton(
                        recipient: $draftAccount.emailRecipient,
                        contactIdentifier: $draftAccount.contactIdentifier
                    )
                    .onChange(of: draftAccount.emailRecipient) { persistAccount() }
                }

                if !draftAccount.hasConfiguredDestination {
                    Text("Укажите получателя — без этого пересылка не работает")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !draftAccount.destinationSummary.isEmpty {
                    Text("Активные получатели: \(draftAccount.destinationSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Фильтры") {
                Toggle("Умная пересылка", isOn: $draftAccount.smartForwardEnabled)
                    .onChange(of: draftAccount.smartForwardEnabled) { persistAccount() }
                Text("Ждёт заданное время и не пересылает сообщения, которые вы уже просмотрели в MAX (на любом устройстве).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Задержка перед отправкой")
                    Spacer()
                    TextField("", value: $draftAccount.forwardDelaySeconds, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("сек")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: draftAccount.forwardDelaySeconds) {
                    draftAccount.forwardDelaySeconds = min(max(draftAccount.forwardDelaySeconds, 0), 60)
                    persistAccount()
                }
                Text("Применяется перед отправкой. При умной пересылке — до проверки прочтения. 0 — без задержки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Не пересылать свои сообщения", isOn: $draftAccount.skipOwnMessages)
                    .onChange(of: draftAccount.skipOwnMessages) { persistAccount() }
                Toggle("Не пересылать из групповых чатов", isOn: $draftAccount.skipGroupChats)
                    .onChange(of: draftAccount.skipGroupChats) { persistAccount() }
                Toggle("Не пересылать из заглушённых чатов MAX", isOn: $draftAccount.skipMutedChats)
                    .onChange(of: draftAccount.skipMutedChats) { persistAccount() }
                Text("Заглушайте чаты в MAX — приложение подхватит это автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Пересылать [вложение] без текста", isOn: $draftAccount.forwardAttachmentsPlaceholder)
                    .onChange(of: draftAccount.forwardAttachmentsPlaceholder) { persistAccount() }
            }

            Section("Формат сообщения") {
                Picker("Содержимое", selection: $draftAccount.forwardNotificationOnly) {
                    Text("Полный текст (Имя: сообщение)").tag(false)
                    Text("Только уведомление (Имя написал(а) в MAX)").tag(true)
                }
                .onChange(of: draftAccount.forwardNotificationOnly) { persistAccount() }
                Text("«Только уведомление» не передаёт текст сообщения — удобно, если Mac используют несколько человек и вы не хотите, чтобы переписка сохранялась на этом компьютере.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Приложение") {
                Toggle("Запускать при входе в macOS", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Toggle("Режим приватности", isOn: Binding(
                    get: { PrivacySettings.displayPrivacyModeEnabled },
                    set: { appState.setPrivacyModeEnabled($0) }
                ))
                .disabled(!PrivacySettings.canToggle)
                Text(privacyModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if PrivacySettings.isActive && showAuthButton {
                Section("Авторизация MAX") {
                    Button("Войти в MAX для этого аккаунта") {
                        openWindow(id: "auth")
                    }
                    Text("Интерфейс MAX будет показан только для входа и закроется автоматически.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showDiagnostics {
                diagnosticsSection
            }

            if let saveStatus {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canDeleteSelectedAccount {
                Section {
                    Button("Удалить аккаунт", role: .destructive) {
                        appState.removeSelectedAccount()
                        syncDraftFromSelection()
                        saveStatus = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(draftAccount.name)
        .onChange(of: draftAccount.contactIdentifier) { persistAccount() }
    }

    private var privacyModeDescription: String {
        if PrivacySettings.canToggle {
            return "Скрывает интерфейс MAX после входа, отключает журнал и диагностику. Включён по умолчанию; в Debug-сборке можно выключить для отладки."
        }
        return "Включён всегда в собранной версии. Скрывает интерфейс MAX после входа, не пишет журнал и не показывает диагностические настройки — чтобы на этом Mac нельзя было просмотреть чужие диалоги."
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section("Диагностика") {
            Toggle("Трассировка realtime (pipeline_trace)", isOn: $draftAccount.traceRealtimeLogging)
                .onChange(of: draftAccount.traceRealtimeLogging) { persistAccount() }
            Toggle("Поиск mute/уведомлений (mute_probe)", isOn: $draftAccount.muteProbeLogging)
                .onChange(of: draftAccount.muteProbeLogging) { persistAccount() }
            Text("Включите, затем заглушите/разглушите чат в MAX — в логах появятся event=mute_probe с найденными полями.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Подробные логи чатов (chat_raw)", isOn: $draftAccount.verboseChatLogging)
                .onChange(of: draftAccount.verboseChatLogging) { persistAccount() }
            if showAuthButton {
                Button("Войти в MAX для этого аккаунта") {
                    openWindow(id: "auth")
                }
            }
            Button("Отправить тестовое сообщение") {
                sendTestMessage()
            }
            Button("Открыть логи") {
                appState.openLogs()
            }
        }
    }

    private var canDeleteSelectedAccount: Bool {
        guard appState.accountManager.accounts.count > 1,
              let selectedId = appState.selectedAccountId,
              let firstId = appState.accountManager.accounts.first?.id else {
            return false
        }
        return selectedId != firstId
    }

    private func syncDraftFromSelection() {
        if let account = appState.selectedAccount {
            draftAccount = account
        }
    }

    private func persistAccount() {
        appState.accountManager.updateAccount(draftAccount)
        if appState.selectedAccountId != draftAccount.id {
            appState.selectAccount(draftAccount.id)
        }
        saveStatus = "Сохранено"
    }

    private func sendTestMessage() {
        persistAccount()
        guard draftAccount.hasConfiguredDestination else {
            saveStatus = "Укажите получателя"
            return
        }
        let forwarder = MessageForwarder()
        let text: String
        if draftAccount.forwardNotificationOnly {
            text = forwarder.formatNotificationOnly(senderName: "Тест")
        } else {
            text = forwarder.formatMessage(
                senderName: "Тест",
                text: "Проверка Max2iMessage (\(draftAccount.name))"
            )
        }

        var sentAny = false
        var lastError: String?

        if draftAccount.forwardDestination == .iMessage || draftAccount.forwardDestination == .both {
            let recipient = draftAccount.effectiveRecipient
            if !recipient.isEmpty {
                do {
                    try forwarder.sendiMessage(to: recipient, text: text)
                    sentAny = true
                } catch {
                    lastError = "iMessage: \(error.localizedDescription)"
                    LogService.shared.log(.sendFailed, accountId: draftAccount.id, message: lastError!, level: "ERROR")
                }
            }
        }

        if draftAccount.forwardDestination == .email || draftAccount.forwardDestination == .both {
            let recipient = draftAccount.effectiveEmailRecipient
            if !recipient.isEmpty {
                do {
                    try forwarder.sendEmail(
                        to: recipient,
                        subject: forwarder.formatEmailSubject(senderName: "Тест"),
                        text: text
                    )
                    sentAny = true
                } catch {
                    let emailError = "Email: \(error.localizedDescription)"
                    lastError = lastError.map { "\($0); \(emailError)" } ?? emailError
                    LogService.shared.log(.sendFailed, accountId: draftAccount.id, message: emailError, level: "ERROR")
                }
            }
        }

        if sentAny {
            saveStatus = lastError == nil ? "Тест отправлен" : "Частично отправлено: \(lastError!)"
        } else {
            saveStatus = "Ошибка: \(lastError ?? "получатель не настроен")"
        }
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
