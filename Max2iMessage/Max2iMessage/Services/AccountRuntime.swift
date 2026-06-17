import Foundation
import WebKit

@MainActor
final class AccountRuntime: MaxWebSessionDelegate {
    let accountId: UUID
    private var account: Account
    private let session: MaxWebSession
    private let dedupStore: DedupStore
    private let globalForwardDedup: GlobalForwardDedup
    private let reconnectPolicy = ReconnectPolicy()
    private let forwarder = MessageForwarder()
    private var reconnectTask: Task<Void, Never>?
    private var syncWatchdogTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var myUserId: String?
    private var isSessionSynced = false
    private var historyCutoffMs: Int64 = 0
    private var lastBridgeActivityAt = Date()
    private var lastObservedPacketCount = 0
    private var staleHeartbeatCount = 0
    private var lastTrafficLogAt = Date.distantPast
    private var lastNavigationFinishedAt = Date.distantPast
    private var monitorMissingRetries = 0
    private var lastHeartbeatMessageAt = 0
    private var wsClosedAt: Date?
    private var isMonitoringActive = false
    private(set) var monitoringPauseReason: String?
    private var chatReadMarks: [String: Int64] = [:]
    private var pendingForwardMessageIds: Set<String> = []
    private var pendingForwardTasks: [String: Task<Void, Never>] = [:]
    private let lastReplyStore: LastReplyStore
    private var pendingBridgeReplyTexts: Set<String> = []
    private var recentBridgeSentTexts: [String: Date] = [:]
    private var inboundReplyTask: Task<Void, Never>?

    private var forwardDelayNanoseconds: UInt64 {
        let seconds = max(0, account.forwardDelaySeconds)
        return UInt64(seconds * 1_000_000_000)
    }

    var status: AccountStatus = .offline
    private(set) var replyStatusMessage: String?
    var onStatusChange: ((AccountStatus) -> Void)?
    var onStatsChange: (() -> Void)?
    var onMaxUserIdChange: ((String) -> Void)?
    var onReplyStatusChange: ((String?) -> Void)?

    private let statsUpdater: () -> DailyStats
    private let statsRecorder: (DailyStats) -> Void

    init(
        account: Account,
        lastReplyStore: LastReplyStore,
        statsUpdater: @escaping () -> DailyStats,
        statsRecorder: @escaping (DailyStats) -> Void
    ) {
        self.accountId = account.id
        self.account = account
        self.lastReplyStore = lastReplyStore
        self.session = MaxWebSession(accountId: account.id)
        self.dedupStore = DedupStore(accountId: account.id)
        self.globalForwardDedup = .shared
        self.statsUpdater = statsUpdater
        self.statsRecorder = statsRecorder
        self.session.delegate = self
    }

    var webView: WKWebView { session.webView }

    func start() {
        guard account.enabled else {
            updateStatus(.offline)
            return
        }
        guard monitoringPauseReason == nil else {
            updateStatus(.offline)
            return
        }
        guard !isMonitoringActive else { return }
        isMonitoringActive = true
        isSessionSynced = false
        historyCutoffMs = 0
        lastNavigationFinishedAt = .distantPast
        monitorMissingRetries = 0
        HiddenWebViewHost.attach(webView: session.webView, accountId: accountId)
        updateStatus(.reconnecting)
        session.load()
        startKeepAlive()
        syncMonitorOptions()
        LogService.shared.log(.reconnect, accountId: accountId, message: "Starting web session")
    }

    func stop() {
        tearDownMonitoring()
        monitoringPauseReason = nil
        updateStatus(.offline)
    }

    func suspendMonitoring(reason: String) {
        if monitoringPauseReason == reason, !isMonitoringActive {
            return
        }
        monitoringPauseReason = reason
        tearDownMonitoring()
        updateStatus(.offline)
        LogService.shared.log(.reconnect, accountId: accountId, message: "Monitoring suspended: \(reason)")
    }

    func resumeMonitoring() {
        monitoringPauseReason = nil
        guard account.enabled else {
            updateStatus(.offline)
            return
        }
        guard !isMonitoringActive else { return }
        start()
    }

    private func tearDownMonitoring() {
        isMonitoringActive = false
        cancelPendingForwardTasks()
        inboundReplyTask?.cancel()
        inboundReplyTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        syncWatchdogTask?.cancel()
        syncWatchdogTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        HiddenWebViewHost.detach(accountId: accountId)
        session.webView.stopLoading()
    }

    private func cancelPendingForwardTasks() {
        for task in pendingForwardTasks.values {
            task.cancel()
        }
        pendingForwardTasks.removeAll()
        pendingForwardMessageIds.removeAll()
    }

    func updateAccount(_ account: Account) {
        let wasEnabled = self.account.enabled
        self.account = account
        syncMonitorOptions()
        if !account.enabled {
            stop()
        }
    }

    func reload() {
        guard monitoringPauseReason == nil else { return }
        isSessionSynced = false
        historyCutoffMs = 0
        lastObservedPacketCount = 0
        staleHeartbeatCount = 0
        lastHeartbeatMessageAt = 0
        reconnectPolicy.reset()
        session.reload()
    }

    // MARK: - MaxWebSessionDelegate

    func webSession(_ session: MaxWebSession, didReceive event: BridgeEvent) {
        markBridgeActivity()

        switch event.type {
        case .newMessage:
            handleNewMessage(event.payload)
        case .wsClosed:
            handleWebSocketClosed(event.payload)
        case .wsOpen:
            handleWebSocketOpen(event.payload)
        case .authCheck:
            if let userId = MessageMonitorParser.string(from: event.payload["userId"]) {
                noteMaxUserId(userId)
            }
            let hasToken = MessageMonitorParser.boolValue(event.payload["hasToken"])
            if !hasToken {
                updateStatus(.needsAuth)
                LogService.shared.log(.authLost, accountId: accountId, message: "Session token missing")
            }
        case .authReady:
            if let userId = MessageMonitorParser.string(from: event.payload["userId"]) {
                noteMaxUserId(userId)
            }
            refreshMyUserIdFromSession()
            reconnectPolicy.reset()
            markSessionSynced(log: "Authenticated")
            syncWatchdogTask?.cancel()
            syncWatchdogTask = nil
            monitorMissingRetries = 0
            updateStatus(.online)
        case .chatsSynced:
            refreshMyUserIdFromSession()
            markSessionSynced(log: "Chats synced, count=\(event.payload["chatCount"] as? Int ?? 0)")
            syncWatchdogTask?.cancel()
            syncWatchdogTask = nil
            monitorMissingRetries = 0
            updateStatus(.online)
        case .heartbeat:
            handleHeartbeat(event.payload)
        case .messageTraffic:
            handleMessageTraffic(event.payload)
        case .monitorReady:
            startSyncWatchdog()
        case .chatRaw:
            LogService.shared.logChatRaw(accountId: accountId, payload: event.payload)
        case .muteProbe:
            LogService.shared.logMuteProbe(accountId: accountId, payload: event.payload)
        case .messageObserved:
            handleMessageObserved(event.payload)
        case .readMark:
            handleReadMark(event.payload)
        case .wsOutSend:
            if account.effectiveTraceRealtimeLogging {
                let chatId = MessageMonitorParser.string(from: event.payload["chatId"]) ?? "?"
                let textLength = event.payload["textLength"] as? Int ?? 0
                LogService.shared.log(
                    .pipelineTrace,
                    accountId: accountId,
                    message: "ws_out_send chat=\(chatId) textLength=\(textLength)"
                )
            }
        case .maxSendResult:
            let ok = MessageMonitorParser.boolValue(event.payload["ok"])
            let chatId = MessageMonitorParser.string(from: event.payload["chatId"]) ?? "?"
            if ok {
                LogService.shared.log(.replySent, accountId: accountId, message: "MAX send confirmed chat=\(chatId)")
            } else {
                let error = MessageMonitorParser.string(from: event.payload["error"]) ?? "unknown"
                LogService.shared.log(.replyFailed, accountId: accountId, message: "MAX send failed chat=\(chatId) error=\(error)", level: "ERROR")
            }
        case .domActivity, .unknown:
            break
        }
    }

    func handleInboundIMessage(_ inbound: InboundIMessage) {
        guard account.supportsIMessageReply else { return }
        guard account.enabled, isMonitoringActive else { return }

        let text = inbound.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !IMessagesDatabaseMonitor.looksLikeForwardedNotification(text) else { return }
        guard !lastReplyStore.wasRecentlySentToIMessage(accountId: accountId, text: text) else { return }
        guard !pendingBridgeReplyTexts.contains(text) else { return }

        LogService.shared.log(
            .replyDetected,
            accountId: accountId,
            message: "iMessage reply row=\(inbound.rowId) textLength=\(text.count)"
        )

        inboundReplyTask?.cancel()
        inboundReplyTask = Task { [weak self] in
            await self?.processInboundReply(text)
        }
    }

    private func processInboundReply(_ text: String) async {
        guard !Task.isCancelled else { return }

        guard let target = lastReplyStore.target(for: accountId) else {
            updateReplyStatus("Нет активного адресата")
            return
        }

        if target.isExpired(windowMinutes: account.replyWindowMinutes) {
            lastReplyStore.clearTarget(accountId: accountId)
            updateReplyStatus("Окно ответа истекло")
            return
        }

        guard isSessionSynced else {
            updateReplyStatus("MAX не синхронизирован")
            recordReplyError()
            return
        }

        pendingBridgeReplyTexts.insert(text)
        noteBridgeSentText(text)
        defer { pendingBridgeReplyTexts.remove(text) }

        let result = await session.sendText(chatId: target.chatId, text: text)
        guard !Task.isCancelled else { return }

        if result.ok {
            var updated = statsUpdater()
            updated.recordReply()
            statsRecorder(updated)
            onStatsChange?()
            updateReplyStatus("Ответ отправлен в MAX (\(target.senderName))")
            LogService.shared.log(
                .replySent,
                accountId: accountId,
                message: "chat=\(target.chatId) to=\(target.senderName) cid=\(result.cid ?? 0)"
            )
        } else {
            recentBridgeSentTexts.removeValue(forKey: text)
            recordReplyError()
            let error = result.error ?? "unknown"
            updateReplyStatus("Ошибка ответа: \(error)")
            LogService.shared.log(.replyFailed, accountId: accountId, message: error, level: "ERROR")
        }
    }

    func webSessionDidFinishNavigation(_ session: MaxWebSession) {
        lastNavigationFinishedAt = Date()
        syncMonitorOptions()
        refreshMyUserIdFromSession()
        Task {
            let probe = await session.probeMonitor()
            if probe.installed {
                monitorMissingRetries = 0
                return
            }
            LogService.shared.log(
                .reconnect,
                accountId: accountId,
                message: "Monitor not ready after page load: \(probe.summary)"
            )
        }
    }

    func webSession(_ session: MaxWebSession, didChangeAuth isAuthenticated: Bool) {
        if isAuthenticated {
            reconnectPolicy.reset()
            refreshAuthStatus()
        } else {
            updateStatus(.needsAuth)
            LogService.shared.log(.authLost, accountId: accountId, message: "Not authenticated")
        }
    }

    func webSessionDidTerminate(_ session: MaxWebSession) {
        scheduleReconnect(reason: "WebContent process terminated")
    }

    func webSessionDidFail(_ session: MaxWebSession, error: String) {
        LogService.shared.log(.error, accountId: accountId, message: error, level: "ERROR")
        scheduleReconnect(reason: error)
    }

    // MARK: - Private

    private func handleNewMessage(_ payload: [String: Any]) {
        guard account.enabled else { return }
        guard let message = MessageMonitorParser.makeMessage(from: payload) else {
            LogService.shared.log(.error, accountId: accountId, message: "Failed to parse message payload", level: "WARN")
            return
        }

        tracePipeline("received", message)

        guard isSessionSynced else {
            recordFiltered()
            tracePipeline("skip_warmup", message)
            LogService.shared.log(
                .messageDetected,
                accountId: accountId,
                message: "Skipped warmup message id=\(message.id) chat=\(message.chatId)"
            )
            return
        }

        if isHistoricalMessage(message) {
            recordFiltered()
            tracePipeline("skip_historical", message)
            LogService.shared.log(
                .messageDetected,
                accountId: accountId,
                message: "Skipped historical message id=\(message.id) chat=\(message.chatId)"
            )
            return
        }

        if isRecentBridgeSentText(message.displayText) {
            recordFiltered()
            tracePipeline("skip_bridge_echo", message)
            LogService.shared.log(
                .messageDetected,
                accountId: accountId,
                message: "Skipped bridge echo id=\(message.id)"
            )
            return
        }

        let payloadMyUserId = MessageMonitorParser.string(from: payload["myUserId"]) ?? myUserId
        if let payloadMyUserId {
            noteMaxUserId(payloadMyUserId)
        }

        if account.skipOwnMessages && MessageMonitorParser.isOwnMessage(payload: payload, myUserId: payloadMyUserId) {
            recordFiltered()
            tracePipeline("skip_own", message)
            LogService.shared.log(
                .messageDetected,
                accountId: accountId,
                message: "Skipped own message id=\(message.id) senderId=\(message.senderId) myUserId=\(payloadMyUserId ?? "-")"
            )
            return
        }
        if account.skipGroupChats {
            if !message.chatTypeKnown {
                recordFiltered()
                tracePipeline("skip_unknown_type", message)
                LogService.shared.log(.messageDetected, accountId: accountId, message: "Skipped unknown chat type id=\(message.id)")
                return
            }
            if message.isGroupChat {
                recordFiltered()
                tracePipeline("skip_group", message)
                LogService.shared.log(.messageDetected, accountId: accountId, message: "Skipped group chat id=\(message.id)")
                return
            }
        }
        if account.skipMutedChats && message.chatMuteKnown && message.isMutedChat {
            recordFiltered()
            tracePipeline("skip_muted", message)
            LogService.shared.log(.messageDetected, accountId: accountId, message: "Skipped muted chat id=\(message.id) chat=\(message.chatId)")
            return
        }

        var displayText = message.displayText
        if displayText.isEmpty {
            if account.forwardAttachmentsPlaceholder && message.hasAttachment {
                displayText = "[вложение]"
            } else {
                recordFiltered()
                tracePipeline("skip_empty", message)
                LogService.shared.log(.messageDetected, accountId: accountId, message: "Skipped empty message id=\(message.id)")
                return
            }
        }

        var stats = statsUpdater()
        stats.recordReceived()
        statsRecorder(stats)
        onStatsChange?()

        tracePipeline("accept", message)

        LogService.shared.log(
            .messageDetected,
            accountId: accountId,
            message: "chat=\(message.chatId) id=\(message.id) from=\(message.senderName)"
        )

        if account.smartForwardEnabled {
            scheduleSmartForward(
                message: message,
                displayText: displayText,
                payload: payload,
                payloadMyUserId: payloadMyUserId
            )
        } else if forwardDelayNanoseconds > 0 {
            scheduleDelayedForward(
                message: message,
                displayText: displayText,
                payloadMyUserId: payloadMyUserId
            )
        } else {
            guard claimAndForward(message: message, displayText: displayText, payloadMyUserId: payloadMyUserId) else {
                return
            }
        }
    }

    private func scheduleSmartForward(
        message: MaxMessage,
        displayText: String,
        payload: [String: Any],
        payloadMyUserId: String?
    ) {
        guard !pendingForwardMessageIds.contains(message.id) else {
            tracePipeline("skip_pending", message)
            return
        }

        let arrivalChatMark = MessageMonitorParser.int64(from: payload["chatMark"])
        let messageTime = MessageMonitorParser.int64(from: payload["messageTime"]) ?? message.timestamp

        pendingForwardMessageIds.insert(message.id)
        let messageId = message.id
        let delayNs = forwardDelayNanoseconds
        let task = Task { [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingForwardMessageIds.remove(messageId)
            self.pendingForwardTasks.removeValue(forKey: messageId)

            if self.isMessageRead(
                chatId: message.chatId,
                messageTime: messageTime,
                arrivalChatMark: arrivalChatMark
            ) {
                self.recordFiltered()
                self.tracePipeline("skip_read", message)
                LogService.shared.log(
                    .messageDetected,
                    accountId: self.accountId,
                    message: "Skipped read message id=\(message.id) chat=\(message.chatId) time=\(messageTime)"
                )
                return
            }

            _ = self.claimAndForward(
                message: message,
                displayText: displayText,
                payloadMyUserId: payloadMyUserId
            )
        }
        pendingForwardTasks[messageId] = task
    }

    private func scheduleDelayedForward(
        message: MaxMessage,
        displayText: String,
        payloadMyUserId: String?
    ) {
        guard !pendingForwardMessageIds.contains(message.id) else {
            tracePipeline("skip_pending", message)
            return
        }

        pendingForwardMessageIds.insert(message.id)
        let messageId = message.id
        let delayNs = forwardDelayNanoseconds
        let task = Task { [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingForwardMessageIds.remove(messageId)
            self.pendingForwardTasks.removeValue(forKey: messageId)

            _ = self.claimAndForward(
                message: message,
                displayText: displayText,
                payloadMyUserId: payloadMyUserId
            )
        }
        pendingForwardTasks[messageId] = task
    }

    @discardableResult
    private func claimAndForward(
        message: MaxMessage,
        displayText: String,
        payloadMyUserId: String?
    ) -> Bool {
        let globalKey = GlobalForwardDedup.makeKey(
            maxUserId: payloadMyUserId ?? myUserId,
            accountId: accountId,
            message: message
        )
        guard globalForwardDedup.tryClaim(key: globalKey) else {
            recordFiltered()
            tracePipeline("skip_global_duplicate", message)
            LogService.shared.log(
                .messageDetected,
                accountId: accountId,
                message: "Skipped duplicate MAX message id=\(message.id) key=\(globalKey) (already forwarded by another account)"
            )
            return false
        }

        guard dedupStore.markProcessed(accountId: accountId, message: message) else {
            tracePipeline("skip_duplicate", message)
            LogService.shared.log(.messageDetected, accountId: accountId, message: "Skipped duplicate id=\(message.id)")
            return false
        }

        Task {
            await forwardMessage(message, displayText: displayText)
        }
        return true
    }

    private func isMessageRead(chatId: String, messageTime: Int64, arrivalChatMark: Int64?) -> Bool {
        guard messageTime > 0 else { return false }
        if let arrivalChatMark, arrivalChatMark >= messageTime {
            return true
        }
        if let cachedMark = chatReadMarks[chatId], cachedMark >= messageTime {
            return true
        }
        return false
    }

    private func handleReadMark(_ payload: [String: Any]) {
        guard MessageMonitorParser.boolValue(payload["setAsUnread"]) == false else { return }
        guard let chatId = MessageMonitorParser.string(from: payload["chatId"]),
              let mark = MessageMonitorParser.int64(from: payload["mark"]) else { return }

        let eventUserId = MessageMonitorParser.string(from: payload["userId"])
        let payloadMyUserId = MessageMonitorParser.string(from: payload["myUserId"]) ?? myUserId
        guard let payloadMyUserId, let eventUserId, eventUserId == payloadMyUserId else { return }

        let previous = chatReadMarks[chatId] ?? 0
        if mark > previous {
            chatReadMarks[chatId] = mark
        }
    }

    private func forwardMessage(_ message: MaxMessage, displayText: String) async {
        let globalKey = GlobalForwardDedup.makeKey(
            maxUserId: myUserId,
            accountId: accountId,
            message: message
        )

        guard account.hasConfiguredDestination else {
            var updated = statsUpdater()
            updated.recordError()
            statsRecorder(updated)
            onStatsChange?()
            LogService.shared.log(.sendFailed, accountId: accountId, message: "Recipient not configured", level: "ERROR")
            return
        }

        let body: String
        if account.forwardNotificationOnly {
            body = forwarder.formatNotificationOnly(senderName: message.senderName)
        } else {
            body = forwarder.formatMessage(
                senderName: message.senderName,
                text: displayText
            )
        }

        var sentAny = false
        var sentViaIMessage = false
        var lastError: Error?

        if account.forwardDestination == .iMessage || account.forwardDestination == .both {
            let recipient = account.effectiveRecipient
            if !recipient.isEmpty {
                do {
                    try forwarder.sendiMessage(to: recipient, text: body)
                    sentAny = true
                    sentViaIMessage = true
                    LogService.shared.log(
                        .messageSent,
                        accountId: accountId,
                        message: "channel=iMessage to=\(recipient) id=\(message.id) key=\(globalKey) maxUserId=\(myUserId ?? "-")"
                    )
                } catch {
                    lastError = error
                    LogService.shared.log(.sendFailed, accountId: accountId, message: "iMessage: \(error.localizedDescription)", level: "ERROR")
                }
            } else if account.forwardDestination == .iMessage {
                lastError = MessageForwarderError.emptyRecipient("iMessage")
                LogService.shared.log(.sendFailed, accountId: accountId, message: "iMessage recipient not configured", level: "ERROR")
            }
        }

        if account.forwardDestination == .email || account.forwardDestination == .both {
            let recipient = account.effectiveEmailRecipient
            if !recipient.isEmpty {
                let subject = forwarder.formatEmailSubject(senderName: message.senderName)
                do {
                    try forwarder.sendEmail(to: recipient, subject: subject, text: body)
                    sentAny = true
                    LogService.shared.log(
                        .messageSent,
                        accountId: accountId,
                        message: "channel=email to=\(recipient) id=\(message.id) key=\(globalKey) maxUserId=\(myUserId ?? "-")"
                    )
                } catch {
                    lastError = error
                    LogService.shared.log(.sendFailed, accountId: accountId, message: "Email: \(error.localizedDescription)", level: "ERROR")
                }
            } else if account.forwardDestination == .email {
                lastError = MessageForwarderError.emptyRecipient("Email")
                LogService.shared.log(.sendFailed, accountId: accountId, message: "Email recipient not configured", level: "ERROR")
            }
        }

        var updated = statsUpdater()
        if sentAny {
            updated.recordSent()
            if sentViaIMessage && account.supportsIMessageReply {
                lastReplyStore.setTarget(
                    accountId: accountId,
                    target: LastReplyTarget(
                        chatId: message.chatId,
                        senderName: message.senderName,
                        messageId: message.id,
                        forwardedAt: .now
                    )
                )
                lastReplyStore.noteOutboundText(accountId: accountId, text: body)
                updateReplyStatus("Ожидает ответ: \(message.senderName)")
            }
        } else {
            updated.recordError()
            if let lastError {
                LogService.shared.log(.sendFailed, accountId: accountId, message: lastError.localizedDescription, level: "ERROR")
            }
        }
        statsRecorder(updated)
        onStatsChange?()
    }

    private func startSyncWatchdog() {
        syncWatchdogTask?.cancel()
        syncWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.account.enabled, !self.isSessionSynced else { return }
            LogService.shared.log(
                .reconnect,
                accountId: self.accountId,
                message: "Chats sync timeout after WebSocket open, reloading"
            )
            self.session.reload()
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.account.enabled else { continue }

                let sinceNavigation = Date().timeIntervalSince(self.lastNavigationFinishedAt)
                if sinceNavigation < 15 {
                    continue
                }

                tick += 1
                await self.session.nudgeMonitor()
                if let ping = await self.session.nativePingMonitor() {
                    self.handleNativePing(ping, tick: tick)
                }

                guard tick % 4 == 0 else { continue }

                let monitorAlive = await self.session.isMonitorAlive()
                if !monitorAlive {
                    let probe = await self.session.probeMonitor()
                    self.monitorMissingRetries += 1
                    self.updateStatus(.reconnecting)
                    LogService.shared.log(
                        .reconnect,
                        accountId: self.accountId,
                        message: "Monitor script missing (attempt \(self.monitorMissingRetries)): \(probe.summary)"
                    )
                    if self.monitorMissingRetries >= 3 {
                        self.monitorMissingRetries = 0
                        self.isSessionSynced = false
                        self.updateStatus(.reconnecting)
                        LogService.shared.log(
                            .reconnect,
                            accountId: self.accountId,
                            message: "Rebuilding monitoring WebView after repeated monitor failures"
                        )
                        self.session.rebuildWebView()
                    }
                    continue
                }
                self.monitorMissingRetries = 0

                let authenticated = await self.session.checkAuthentication()
                if !authenticated {
                    LogService.shared.log(.authLost, accountId: self.accountId, message: "Auth token missing on heartbeat")
                    self.updateStatus(.needsAuth)
                    continue
                }

                self.refreshAuthStatus()

                let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                let recentMessage = self.lastHeartbeatMessageAt > 0
                    && (nowMs - self.lastHeartbeatMessageAt) < 180_000
                let bridgeIdle = Date().timeIntervalSince(self.lastBridgeActivityAt)
                if self.isSessionSynced && bridgeIdle > 300 && !recentMessage {
                    self.forceReload(reason: "No bridge activity for \(Int(bridgeIdle))s")
                }
            }
        }
    }

    private func refreshAuthStatus() {
        if isSessionSynced {
            updateStatus(.online)
        } else {
            updateStatus(.reconnecting)
        }
    }

    func refreshMonitorOptions() {
        syncMonitorOptions()
    }

    private func syncMonitorOptions() {
        Task {
            await session.syncMonitorOptions(
                verboseLogging: account.effectiveVerboseChatLogging,
                muteProbeLogging: account.effectiveMuteProbeLogging
            )
        }
    }

    private func handleMessageObserved(_ payload: [String: Any]) {
        guard account.effectiveTraceRealtimeLogging else { return }
        let chatId = payload["chatId"] as? String ?? "?"
        let messageId = payload["messageId"] as? String ?? "?"
        let sessionReady = payload["sessionReady"] as? Bool ?? false
        LogService.shared.log(
            .pipelineTrace,
            accountId: accountId,
            message: "js_observed id=\(messageId) chat=\(chatId) sessionReady=\(sessionReady)"
        )
    }

    private func tracePipeline(_ stage: String, _ message: MaxMessage) {
        guard account.effectiveTraceRealtimeLogging else { return }
        LogService.shared.log(
            .pipelineTrace,
            accountId: accountId,
            message: "\(stage) id=\(message.id) chat=\(message.chatId)"
        )
    }

    private func handleNativePing(_ ping: NativePingStats, tick: Int) {
        markBridgeActivity()
        if ping.lastMessageAt > lastHeartbeatMessageAt {
            lastHeartbeatMessageAt = ping.lastMessageAt
        }

        let msgAge = ping.lastMessageAt > 0 ? ping.now - ping.lastMessageAt : -1
        if account.effectiveTraceRealtimeLogging && tick % 4 == 0 {
            LogService.shared.log(
                .pipelineTrace,
                accountId: accountId,
                message: "native_ping packets=\(ping.packetCount) msgs=\(ping.messageCount) lastMsgAgeMs=\(msgAge)"
            )
        }

        if isSessionSynced && msgAge > 45_000 {
            LogService.shared.log(
                .reconnect,
                accountId: accountId,
                message: "No WS messages for \(msgAge / 1000)s, nudging WebView"
            )
        }
    }

    private func handleWebSocketClosed(_ payload: [String: Any]) {
        wsClosedAt = Date()
        let code = payload["code"] as? Int ?? -1
        let reason = payload["reason"] as? String ?? ""
        let wasClean = payload["wasClean"] as? Bool ?? false
        updateStatus(.reconnecting)
        LogService.shared.log(
            .reconnect,
            accountId: accountId,
            message: "WebSocket closed code=\(code) clean=\(wasClean) reason=\(reason.isEmpty ? "-" : reason), waiting for MAX reconnect"
        )
        scheduleWebSocketRecoveryWatchdog()
    }

    private func handleWebSocketOpen(_ payload: [String: Any]) {
        wsClosedAt = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectPolicy.reset()

        let resumed = payload["resumed"] as? Bool ?? false
        if resumed {
            markSessionSynced(
                log: "WebSocket reconnected, resumed with cached chats",
                resetHistoryCutoff: false
            )
            updateStatus(.online)
        } else {
            isSessionSynced = false
            historyCutoffMs = 0
            LogService.shared.log(.reconnect, accountId: accountId, message: "WebSocket opened, awaiting chats sync")
            startSyncWatchdog()
        }
    }

    private func scheduleWebSocketRecoveryWatchdog() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.wsClosedAt != nil else { return }
            self.forceReload(reason: "WebSocket closed for 45s without reopen")
        }
    }

    private func markSessionSynced(log: String, resetHistoryCutoff: Bool = true) {
        isSessionSynced = true
        if resetHistoryCutoff {
            historyCutoffMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        syncWatchdogTask?.cancel()
        syncWatchdogTask = nil
        LogService.shared.log(.authSuccess, accountId: accountId, message: log)
    }

    private func isHistoricalMessage(_ message: MaxMessage) -> Bool {
        guard historyCutoffMs > 0, message.timestamp > 0 else { return false }
        let messageMs = Self.timestampMs(message.timestamp)
        return messageMs < historyCutoffMs - 10_000
    }

    private static func timestampMs(_ timestamp: Int64) -> Int64 {
        if timestamp > 1_000_000_000_000 { timestamp }
        else if timestamp > 1_000_000_000 { timestamp * 1000 }
        else { timestamp }
    }

    private func recordFiltered() {
        var stats = statsUpdater()
        stats.recordFiltered()
        statsRecorder(stats)
        onStatsChange?()
    }

    private func markBridgeActivity() {
        lastBridgeActivityAt = Date()
    }

    private func handleHeartbeat(_ payload: [String: Any]) {
        let packetCount = payload["packetCount"] as? Int ?? 0
        let messageCount = payload["messageCount"] as? Int ?? 0
        let sessionReady = payload["sessionReady"] as? Bool ?? false
        let everSynced = payload["everSynced"] as? Bool ?? false
        let lastMessageAt = payload["lastMessageAt"] as? Int ?? 0
        if lastMessageAt > lastHeartbeatMessageAt {
            lastHeartbeatMessageAt = lastMessageAt
        }

        if !isSessionSynced && everSynced {
            markSessionSynced(
                log: "Session resumed via heartbeat (packets=\(packetCount), messages=\(messageCount))",
                resetHistoryCutoff: false
            )
        }

        if isSessionSynced {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let recentMessage = lastHeartbeatMessageAt > 0
                && (nowMs - lastHeartbeatMessageAt) < 180_000

            if packetCount > lastObservedPacketCount {
                staleHeartbeatCount = 0
                lastObservedPacketCount = packetCount
                updateStatus(.online)
            } else if recentMessage {
                staleHeartbeatCount = 0
                updateStatus(.online)
            } else {
                staleHeartbeatCount += 1
                if staleHeartbeatCount >= 5 {
                    forceReload(reason: "No new WS packets (packets=\(packetCount), messages=\(messageCount), lastMsgAge=\(nowMs - lastHeartbeatMessageAt)ms)")
                    return
                }
                updateStatus(.reconnecting)
                LogService.shared.log(
                    .reconnect,
                    accountId: accountId,
                    message: "WS traffic stalled (\(staleHeartbeatCount)/5), packets=\(packetCount) messages=\(messageCount) ready=\(sessionReady)"
                )
            }
        }

        if account.effectiveTraceRealtimeLogging {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let msgAge = lastHeartbeatMessageAt > 0 ? nowMs - lastHeartbeatMessageAt : -1
            LogService.shared.log(
                .pipelineTrace,
                accountId: accountId,
                message: "heartbeat packets=\(packetCount) msgs=\(messageCount) synced=\(isSessionSynced) lastMsgAgeMs=\(msgAge)"
            )
        }
    }

    private func handleMessageTraffic(_ payload: [String: Any]) {
        let now = Date()
        guard now.timeIntervalSince(lastTrafficLogAt) >= 30 else { return }
        lastTrafficLogAt = now

        let reason = payload["reason"] as? String ?? "unknown"
        let messageCount = payload["messageCount"] as? Int ?? 0
        LogService.shared.log(
            .messageDetected,
            accountId: accountId,
            message: "WS traffic seen (\(reason)), total=\(messageCount)"
        )
    }

    private func forceReload(reason: String) {
        staleHeartbeatCount = 0
        lastObservedPacketCount = 0
        isSessionSynced = false
        historyCutoffMs = 0
        wsClosedAt = nil
        monitorMissingRetries = 0
        updateStatus(.reconnecting)
        LogService.shared.log(.reconnect, accountId: accountId, message: "\(reason), reloading")
        session.rebuildWebView()
    }

    private func scheduleReconnect(reason: String) {
        guard account.enabled else { return }
        updateStatus(.reconnecting)
        reconnectTask?.cancel()
        let delay = reconnectPolicy.nextDelay
        LogService.shared.log(.reconnect, accountId: accountId, message: "\(reason), retry in \(Int(delay))s")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.session.reload()
        }
    }

    private func updateStatus(_ newStatus: AccountStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func noteMaxUserId(_ userId: String) {
        guard myUserId != userId else { return }
        myUserId = userId
        LogService.shared.log(.authSuccess, accountId: accountId, message: "Runtime MAX userId=\(userId)")
        onMaxUserIdChange?(userId)
    }

    private func refreshMyUserIdFromSession() {
        Task {
            if let userId = await session.fetchAuthUserId() {
                noteMaxUserId(userId)
            }
        }
    }

    private func updateReplyStatus(_ message: String?) {
        replyStatusMessage = message
        onReplyStatusChange?(message)
    }

    private func recordReplyError() {
        var updated = statsUpdater()
        updated.recordError()
        statsRecorder(updated)
        onStatsChange?()
    }

    private func noteBridgeSentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentBridgeSentTexts[trimmed] = Date()
        pruneBridgeSentTexts()
    }

    private func isRecentBridgeSentText(_ text: String) -> Bool {
        pruneBridgeSentTexts()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return recentBridgeSentTexts[trimmed] != nil
    }

    private func pruneBridgeSentTexts() {
        let cutoff = Date().addingTimeInterval(-120)
        recentBridgeSentTexts = recentBridgeSentTexts.filter { $0.value >= cutoff }
    }
}
