import AppKit
import Foundation
import SQLite3

struct InboundIMessage: Sendable {
    let rowId: Int64
    let text: String
    let date: Date
    let isFromMe: Bool
    let usesRawTextColumn: Bool
    let hasBridgeMarkerInBody: Bool
    let associatedMessageType: Int64
    let associatedMessageGuid: String?
    let threadOriginatorGuid: String?

    var isInlineReply: Bool {
        IMessagesDatabaseMonitor.isInlineReplyType(associatedMessageType)
    }
}

enum IMessagesDatabaseMonitorError: LocalizedError {
    case databaseUnavailable
    case recipientNotFound

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "Нет доступа к базе Messages. Разрешите Full Disk Access для Max2iMessage."
        case .recipientNotFound:
            "Диалог iMessage с указанным получателем не найден."
        }
    }
}

final class IMessagesDatabaseMonitor: @unchecked Sendable {
    static let shared = IMessagesDatabaseMonitor()

    var onInboundMessage: (@Sendable (UUID, InboundIMessage) -> Void)?

    private let queue = DispatchQueue(label: "ilcomm.Max2iMessage.imessages-db")
    private var registrations: [UUID: String] = [:]
    private var lastRowIdByAccount: [UUID: Int64] = [:]
    private var bridgeRowIds: [UUID: Set<Int64>] = [:]
    private var pendingTextRows: [UUID: [Int64: Date]] = [:]
    private let pendingTextTimeout: TimeInterval = 60
    private var pollTimer: DispatchSourceTimer?
    private(set) var hasDatabaseAccess = false
    private(set) var lastAccessError: String?
    private var lastAccessCheckAt = Date.distantPast

    private var databaseURL: URL {
        AppPaths.messagesDatabaseFile
    }

    private init() {}

    func start() {
        queue.async { [self] in
            refreshAccessLocked(force: true)
            guard pollTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 1.5)
            timer.setEventHandler { [weak self] in
                self?.pollLocked()
            }
            timer.resume()
            pollTimer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    func refreshAccess(waitUntilDone: Bool = false) {
        let work = { [self] in
            refreshAccessLocked(force: true)
        }
        if waitUntilDone {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func register(accountId: UUID, recipient: String) {
        let normalized = Self.normalizeHandle(recipient)
        queue.async { [self] in
            guard !normalized.isEmpty else {
                registrations.removeValue(forKey: accountId)
                lastRowIdByAccount.removeValue(forKey: accountId)
                return
            }
            registrations[accountId] = normalized
            if lastRowIdByAccount[accountId] == nil {
                refreshAccessLocked(force: true)
                lastRowIdByAccount[accountId] = currentMaxRowIdLocked(for: normalized) ?? 0
            }
        }
    }

    func unregister(accountId: UUID) {
        queue.async { [self] in
            registrations.removeValue(forKey: accountId)
            lastRowIdByAccount.removeValue(forKey: accountId)
        }
    }

    func maxOutboundRowId(recipient: String, waitUntilDone: Bool = true) -> Int64 {
        let work = { [self] in
            currentMaxOutboundRowIdLocked(for: recipient) ?? 0
        }
        if waitUntilDone {
            return queue.sync(execute: work)
        }
        var value: Int64 = 0
        queue.sync { value = work() }
        return value
    }

    func findOutboundMessageGuid(
        recipient: String,
        body: String,
        afterRowId: Int64,
        waitUntilDone: Bool = true
    ) -> String? {
        let work = { [self] in
            findOutboundMessageGuidLocked(recipient: recipient, body: body, afterRowId: afterRowId)
        }
        if waitUntilDone {
            return queue.sync(execute: work)
        }
        return nil
    }

    func findMessageText(byGuid guid: String, recipient: String, waitUntilDone: Bool = true) -> String? {
        let work = { [self] in
            findMessageTextLocked(byGuid: guid, recipient: recipient)
        }
        if waitUntilDone {
            return queue.sync(execute: work)
        }
        return nil
    }

    func registerBridgeRow(accountId: UUID, rowId: Int64) {
        queue.async { [self] in
            bridgeRowIds[accountId, default: []].insert(rowId)
            pendingTextRows[accountId]?.removeValue(forKey: rowId)
        }
    }

    func captureOutboundMessageGuid(
        recipient: String,
        body: String,
        afterRowId: Int64,
        accountId: UUID,
        completion: @escaping @Sendable (String?, Int64?) -> Void
    ) {
        queue.async { [self] in
            for delay in [0.4, 1.0, 2.0, 4.0, 6.0] {
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
                if let match = findOutboundMessageMatchLocked(
                    recipient: recipient,
                    body: body,
                    afterRowId: afterRowId
                ) {
                    bridgeRowIds[accountId, default: []].insert(match.rowId)
                    pendingTextRows[accountId]?.removeValue(forKey: match.rowId)
                    completion(match.guid, match.rowId)
                    return
                }
            }
            LogService.shared.log(
                .pipelineTrace,
                message: "bubble_guid_miss afterRowId=\(afterRowId) bodyLength=\(body.count)"
            )
            completion(nil, nil)
        }
    }

    static func normalizeHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("@") { return trimmed }
        return trimmed.filter(\.isNumber)
    }

    static func handlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizeHandle(lhs)
        let right = normalizeHandle(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if left.count >= 10, right.count >= 10 {
            return left.suffix(10) == right.suffix(10)
        }
        return false
    }

    static func looksLikeForwardedNotification(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasSuffix(" написал(а) в MAX") { return true }
        if trimmed == "Новое сообщение в MAX" { return true }
        return false
    }

    static func looksLikeReplyConfirmation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("Отправил сообщение ") || trimmed.contains("Отправил сообщение ")
    }

    static func looksLikeBridgeSystemMessage(_ text: String) -> Bool {
        if isMarked(text) { return true }
        return looksLikeForwardedNotification(text) || looksLikeReplyConfirmation(text)
    }

    static func isMarked(_ text: String) -> Bool {
        BridgeMessageMarker.isMarked(text)
    }

    static func stripMarker(_ text: String) -> String {
        BridgeMessageMarker.strip(text)
    }

    static func isPlausibleUserReplyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { return false }
        let rejectTokens = [
            "NSString", "NSDictionary", "NSAttributedString", "NSMutable",
            "streamtyped", "NSObject", "NSNumber", "NSValue"
        ]
        for token in rejectTokens where trimmed.contains(token) {
            return false
        }
        let letters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        return letters >= max(1, trimmed.count / 3)
    }

    static func shouldTreatAsUserReply(_ message: InboundIMessage) -> Bool {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !isMarked(text) else { return false }
        if message.isFromMe, message.hasBridgeMarkerInBody { return false }
        guard isUserReplyType(message.associatedMessageType) else { return false }
        guard isPlausibleUserReplyText(text) else { return false }
        return true
    }

    static func deduplicatedReplyCandidates(_ messages: [InboundIMessage]) -> [InboundIMessage] {
        var byText: [String: InboundIMessage] = [:]
        for message in messages {
            let key = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if let existing = byText[key] {
                byText[key] = preferReplyCandidate(existing, message)
            } else {
                byText[key] = message
            }
        }
        return byText.values.sorted { $0.rowId < $1.rowId }
    }

    private static func preferReplyCandidate(_ lhs: InboundIMessage, _ rhs: InboundIMessage) -> InboundIMessage {
        if lhs.isInlineReply != rhs.isInlineReply {
            return lhs.isInlineReply ? lhs : rhs
        }
        if lhs.isFromMe != rhs.isFromMe {
            return lhs.isFromMe ? lhs : rhs
        }
        if lhs.associatedMessageGuid != nil && rhs.associatedMessageGuid == nil { return lhs }
        if rhs.associatedMessageGuid != nil && lhs.associatedMessageGuid == nil { return rhs }
        return lhs.rowId >= rhs.rowId ? lhs : rhs
    }

    static func isUserReplyType(_ associatedType: Int64) -> Bool {
        switch associatedType {
        case 0, 1, 3000:
            return true
        default:
            return false
        }
    }

    static func isInlineReplyType(_ associatedType: Int64) -> Bool {
        associatedType == 1 || associatedType == 3000
    }

    static func normalizeMessageGuid(_ guid: String) -> String {
        var value = guid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return "" }
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        return value
    }

    private func refreshAccessLocked(force: Bool = false) {
        let retryInterval: TimeInterval = hasDatabaseAccess ? 5 : 15
        if !force, Date().timeIntervalSince(lastAccessCheckAt) < retryInterval {
            return
        }
        lastAccessCheckAt = Date()

        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            hasDatabaseAccess = false
            lastAccessError = "Файл не найден: \(path)"
            return
        }

        guard let db = openDatabase() else {
            hasDatabaseAccess = false
            lastAccessError = "Нет доступа к \(path). Нужен Full Disk Access."
            return
        }
        sqlite3_close(db)
        hasDatabaseAccess = true
        lastAccessError = nil
    }

    private func pollLocked() {
        guard !registrations.isEmpty else { return }

        refreshAccessLocked()
        guard hasDatabaseAccess else { return }

        for (accountId, recipient) in registrations {
            var pending = pendingTextRows[accountId] ?? [:]
            let now = Date()
            for (rowId, seenAt) in pending where now.timeIntervalSince(seenAt) > pendingTextTimeout {
                pending.removeValue(forKey: rowId)
                LogService.shared.log(
                    .pipelineTrace,
                    message: "imessage_pending_timeout row=\(rowId) account=\(accountId.uuidString.prefix(8))"
                )
            }
            pendingTextRows[accountId] = pending

            let lastRowId = lastRowIdByAccount[accountId] ?? 0
            guard var messages = fetchNewMessagesLocked(recipient: recipient, accountId: accountId) else {
                continue
            }

            let pendingIds = Array(pending.keys)
            if !pendingIds.isEmpty,
               let pendingMessages = fetchMessagesByRowIdsLocked(recipient: recipient, rowIds: pendingIds) {
                let known = Set(messages.map(\.rowId))
                for pendingMessage in pendingMessages where !known.contains(pendingMessage.rowId) {
                    messages.append(pendingMessage)
                }
                messages.sort { $0.rowId < $1.rowId }
            }

            guard !messages.isEmpty else { continue }

            var newestRowId = lastRowId
            var replyCandidates: [InboundIMessage] = []

            for message in messages where message.rowId > lastRowId || pending[message.rowId] != nil {
                if message.rowId > lastRowId {
                    newestRowId = max(newestRowId, message.rowId)
                }

                if isRegisteredBridgeRow(accountId: accountId, rowId: message.rowId) {
                    pendingTextRows[accountId]?.removeValue(forKey: message.rowId)
                    continue
                }

                if Self.shouldTreatAsUserReply(message) {
                    replyCandidates.append(message)
                    pendingTextRows[accountId]?.removeValue(forKey: message.rowId)
                    continue
                }

                let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty {
                    if pending[message.rowId] == nil {
                        pending[message.rowId] = now
                        pendingTextRows[accountId] = pending
                        LogService.shared.log(
                            .pipelineTrace,
                            message: "imessage_pending row=\(message.rowId) fromMe=\(message.isFromMe) type=\(message.associatedMessageType) account=\(accountId.uuidString.prefix(8))"
                        )
                    }
                    continue
                }

                if Self.isMarked(trimmedText) || Self.looksLikeBridgeSystemMessage(trimmedText) || message.hasBridgeMarkerInBody {
                    bridgeRowIds[accountId, default: []].insert(message.rowId)
                }
                pendingTextRows[accountId]?.removeValue(forKey: message.rowId)
            }

            let newCount = messages.filter { $0.rowId > lastRowId }.count
            if !replyCandidates.isEmpty {
                LogService.shared.log(
                    .pipelineTrace,
                    message: "imessage_poll account=\(accountId.uuidString.prefix(8)) lastRow=\(lastRowId) candidates=\(replyCandidates.count)"
                )
            } else if newCount > 0, let sample = messages.last(where: { $0.rowId > lastRowId }) {
                let preview = sample.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(24)
                    .replacingOccurrences(of: "\n", with: " ")
                LogService.shared.log(
                    .pipelineTrace,
                    message: "imessage_skip row=\(sample.rowId) fromMe=\(sample.isFromMe) raw=\(sample.usesRawTextColumn) inline=\(sample.isInlineReply) type=\(sample.associatedMessageType) len=\(sample.text.count) markedBody=\(sample.hasBridgeMarkerInBody) preview=\"\(preview)\""
                )
            }

            for message in Self.deduplicatedReplyCandidates(replyCandidates) {
                onInboundMessage?(accountId, message)
            }

            lastRowIdByAccount[accountId] = newestRowId
        }
    }

    private func isRegisteredBridgeRow(accountId: UUID, rowId: Int64) -> Bool {
        bridgeRowIds[accountId]?.contains(rowId) ?? false
    }

    private func currentMaxRowIdLocked(for recipient: String) -> Int64? {
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let sql = """
        SELECT MAX(m.ROWID)
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        for (index, chatId) in chatIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatId)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func currentMaxOutboundRowIdLocked(for recipient: String) -> Int64? {
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let sql = """
        SELECT MAX(m.ROWID)
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
          AND m.is_from_me = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        for (index, chatId) in chatIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatId)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private struct OutboundMessageMatch {
        let guid: String
        let rowId: Int64
    }

    private func findOutboundMessageMatchLocked(
        recipient: String,
        body: String,
        afterRowId: Int64
    ) -> OutboundMessageMatch? {
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")

        return firstOutboundMatchAfterRowIdLocked(
            db: db,
            chatIds: chatIds,
            placeholders: placeholders,
            afterRowId: afterRowId,
            expectedBody: trimmedBody
        )
    }

    private func findOutboundMessageGuidLocked(
        recipient: String,
        body: String,
        afterRowId: Int64
    ) -> String? {
        findOutboundMessageMatchLocked(recipient: recipient, body: body, afterRowId: afterRowId)?.guid
    }

    private func firstOutboundMatchAfterRowIdLocked(
        db: OpaquePointer,
        chatIds: [Int64],
        placeholders: String,
        afterRowId: Int64,
        expectedBody: String
    ) -> OutboundMessageMatch? {
        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
          AND m.ROWID > ?
          AND m.is_from_me = 1
          AND m.associated_message_type = 0
        ORDER BY m.ROWID ASC
        LIMIT 5
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        for (index, chatId) in chatIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatId)
        }
        sqlite3_bind_int64(statement, Int32(chatIds.count + 1), afterRowId)

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(statement, 0)
            guard let guidPtr = sqlite3_column_text(statement, 1) else { continue }
            let guid = String(cString: guidPtr)
            let rawText = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let attributedBody = blobData(statement: statement, column: 3)
            let text = resolvedMessageText(
                rawText: rawText,
                attributedBody: attributedBody,
                allowAttributedFallback: true
            )
            if !expectedBody.isEmpty, textsMatchForOutbound(expectedBody, text) {
                return OutboundMessageMatch(guid: guid, rowId: rowId)
            }
            if Self.isMarked(text) || Self.looksLikeBridgeSystemMessage(text) {
                return OutboundMessageMatch(guid: guid, rowId: rowId)
            }
            if attributedBody.map({ Self.attributedBodyContainsBridgeMarker($0) }) == true {
                return OutboundMessageMatch(guid: guid, rowId: rowId)
            }
        }
        return nil
    }

    private func findMessageTextLocked(byGuid guid: String, recipient: String) -> String? {
        let normalized = Self.normalizeMessageGuid(guid)
        guard !normalized.isEmpty else { return nil }
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let sql = """
        SELECT m.guid, m.text, m.attributedBody
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
        ORDER BY m.ROWID DESC
        LIMIT 200
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        for (index, chatId) in chatIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatId)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidPtr = sqlite3_column_text(statement, 0) else { continue }
            let storedGuid = String(cString: guidPtr)
            if Self.normalizeMessageGuid(storedGuid) == normalized {
                let rawText = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let attributedBody = blobData(statement: statement, column: 2)
                let text = resolvedMessageText(
                    rawText: rawText,
                    attributedBody: attributedBody,
                    allowAttributedFallback: true
                )
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private func textsMatchForOutbound(_ expected: String, _ actual: String) -> Bool {
        let lhs = BridgeMessageMarker.mark(expected.trimmingCharacters(in: .whitespacesAndNewlines))
        let rhs = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private func fetchNewMessagesLocked(recipient: String, accountId: UUID) -> [InboundIMessage]? {
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let lastRowId = lastRowIdByAccount[accountId] ?? 0
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, m.associated_message_type, m.associated_message_guid, m.thread_originator_guid
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
          AND m.ROWID > ?
          AND m.is_from_me IN (0, 1)
        ORDER BY m.ROWID ASC
        LIMIT 40
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        for (index, chatId) in chatIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatId)
        }
        sqlite3_bind_int64(statement, Int32(chatIds.count + 1), lastRowId)

        var results: [InboundIMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(statement, 0)
            let rawText = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let attributedBody = blobData(statement: statement, column: 2)
            let usesRawTextColumn = !(rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasBridgeMarkerInBody = attributedBody.map { Self.attributedBodyContainsBridgeMarker($0) } ?? false
            let text = resolvedMessageText(
                rawText: rawText,
                attributedBody: attributedBody,
                allowAttributedFallback: true
            )
            let appleDate = sqlite3_column_int64(statement, 3)
            let isFromMe = sqlite3_column_int64(statement, 4) != 0
            let associatedType = sqlite3_column_int64(statement, 5)
            let associatedGuid = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let threadGuid = sqlite3_column_text(statement, 7).map { String(cString: $0) }
            let date = Date(timeIntervalSinceReferenceDate: TimeInterval(appleDate) / 1_000_000_000)
            results.append(
                InboundIMessage(
                    rowId: rowId,
                    text: text,
                    date: date,
                    isFromMe: isFromMe,
                    usesRawTextColumn: usesRawTextColumn,
                    hasBridgeMarkerInBody: hasBridgeMarkerInBody,
                    associatedMessageType: associatedType,
                    associatedMessageGuid: associatedGuid,
                    threadOriginatorGuid: threadGuid
                )
            )
        }
        return results
    }

    private func fetchMessagesByRowIdsLocked(recipient: String, rowIds: [Int64]) -> [InboundIMessage]? {
        guard !rowIds.isEmpty else { return [] }
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let chatPlaceholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let rowPlaceholders = Array(repeating: "?", count: rowIds.count).joined(separator: ", ")
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, m.associated_message_type, m.associated_message_guid, m.thread_originator_guid
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(chatPlaceholders))
          AND m.ROWID IN (\(rowPlaceholders))
        ORDER BY m.ROWID ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for chatId in chatIds {
            sqlite3_bind_int64(statement, bindIndex, chatId)
            bindIndex += 1
        }
        for rowId in rowIds {
            sqlite3_bind_int64(statement, bindIndex, rowId)
            bindIndex += 1
        }

        var results: [InboundIMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(statement, 0)
            let rawText = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let attributedBody = blobData(statement: statement, column: 2)
            let usesRawTextColumn = !(rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasBridgeMarkerInBody = attributedBody.map { Self.attributedBodyContainsBridgeMarker($0) } ?? false
            let text = resolvedMessageText(
                rawText: rawText,
                attributedBody: attributedBody,
                allowAttributedFallback: true
            )
            let appleDate = sqlite3_column_int64(statement, 3)
            let isFromMe = sqlite3_column_int64(statement, 4) != 0
            let associatedType = sqlite3_column_int64(statement, 5)
            let associatedGuid = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let threadGuid = sqlite3_column_text(statement, 7).map { String(cString: $0) }
            let date = Date(timeIntervalSinceReferenceDate: TimeInterval(appleDate) / 1_000_000_000)
            results.append(
                InboundIMessage(
                    rowId: rowId,
                    text: text,
                    date: date,
                    isFromMe: isFromMe,
                    usesRawTextColumn: usesRawTextColumn,
                    hasBridgeMarkerInBody: hasBridgeMarkerInBody,
                    associatedMessageType: associatedType,
                    associatedMessageGuid: associatedGuid,
                    threadOriginatorGuid: threadGuid
                )
            )
        }
        return results
    }

    private func blobData(statement: OpaquePointer?, column: Int32) -> Data? {
        guard let statement else { return nil }
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: length)
    }

    private func resolvedMessageText(rawText: String?, attributedBody: Data?, allowAttributedFallback: Bool) -> String {
        let trimmed = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        guard allowAttributedFallback else { return "" }
        return Self.extractTextFromAttributedBody(attributedBody)
    }

    static func attributedBodyContainsBridgeMarker(_ data: Data) -> Bool {
        data.range(of: BridgeMessageMarker.prefixUTF8Data) != nil
    }

    static func extractTextFromAttributedBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }

        var candidates: [String] = []

        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) {
            candidates.append(attributed.string)
        }

        if let attributed = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: data
        ) {
            candidates.append(attributed.string)
        }

        candidates.append(contentsOf: extractStreamTypedStrings(from: data))

        if let utf8 = String(data: data, encoding: .utf8) {
            let pattern = #"[\p{L}\p{N}][\p{L}\p{N}\s.,!?\-+()]{0,200}"#
            var searchRange = utf8.startIndex..<utf8.endIndex
            while let match = utf8.range(of: pattern, options: .regularExpression, range: searchRange) {
                candidates.append(String(utf8[match]))
                searchRange = match.upperBound..<utf8.endIndex
            }
        }

        if let scanned = bestUTF8Substring(in: data) {
            candidates.append(scanned)
        }

        if let markerRange = data.range(of: BridgeMessageMarker.prefixUTF8Data) {
            let tail = data[markerRange.upperBound...]
            if let tailText = bestUTF8Substring(in: tail) {
                candidates.append(tailText)
            }
        }

        return pickBestReplyCandidate(from: candidates)
    }

    private static func extractStreamTypedStrings(from data: Data) -> [String] {
        var results: [String] = []
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x2B {
                var end = index + 1
                while end < bytes.count, bytes[end] != 0x86, bytes[end] != 0x84, bytes[end] != 0x00 {
                    end += 1
                }
                if end > index + 1, let text = String(bytes: bytes[(index + 1)..<end], encoding: .utf8) {
                    results.append(text)
                }
            }
            index += 1
        }

        let classMarkers = ["NSString", "NSMutableString", "NSAttributedString"]
        for marker in classMarkers {
            guard let markerData = marker.data(using: .utf8) else { continue }
            var searchStart = 0
            while searchStart < data.count,
                  let range = data.range(of: markerData, options: [], in: searchStart..<data.count) {
                let tail = Array(bytes[range.upperBound..<min(bytes.count, range.upperBound + 256)])
                for offset in 0..<tail.count where tail[offset] == 0x2B {
                    var end = offset + 1
                    while end < tail.count, tail[end] != 0x86, tail[end] != 0x84, tail[end] != 0x00 {
                        end += 1
                    }
                    if end > offset + 1, let text = String(bytes: tail[(offset + 1)..<end], encoding: .utf8) {
                        results.append(text)
                    }
                }
                searchStart = range.upperBound
            }
        }
        return results
    }

    private static func pickBestReplyCandidate(from candidates: [String]) -> String {
        let normalized = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let viable = normalized.filter {
            isPlausibleUserReplyText($0) && !isMarked($0) && !looksLikeBridgeSystemMessage($0)
        }

        if viable.count == 1 {
            return viable[0]
        }
        if viable.count > 1 {
            return viable.min { $0.count < $1.count } ?? ""
        }
        return ""
    }

    private static func bestUTF8Substring(in data: Data) -> String? {
        var best = ""
        let bytes = Array(data)
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, end - start <= 240 {
                end += 1
                if let slice = String(bytes: bytes[start..<end], encoding: .utf8) {
                    let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 2,
                       isPlausibleUserReplyText(trimmed),
                       !isMarked(trimmed),
                       !looksLikeBridgeSystemMessage(trimmed),
                       trimmed.count > best.count {
                        best = trimmed
                    }
                }
            }
            start += 1
        }
        return best.isEmpty ? nil : best
    }

    private func chatIdsLocked(for recipient: String) -> [Int64]? {
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT DISTINCT c.ROWID, h.id, h.uncanonicalized_id
        FROM chat c
        INNER JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
        INNER JOIN handle h ON h.ROWID = chj.handle_id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var chatIds: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let chatId = sqlite3_column_int64(statement, 0)
            let handleId = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let uncanonicalized = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            if Self.handlesMatch(recipient, handleId) || Self.handlesMatch(recipient, uncanonicalized) {
                chatIds.append(chatId)
            }
        }
        return Array(Set(chatIds))
    }

    private func openDatabase() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard result == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        return db
    }
}
