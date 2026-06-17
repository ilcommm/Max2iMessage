import Foundation
import SQLite3

struct InboundIMessage: Sendable {
    let rowId: Int64
    let text: String
    let date: Date
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
            guard let messages = fetchNewMessagesLocked(recipient: recipient, accountId: accountId),
                  !messages.isEmpty else {
                continue
            }

            let lastRowId = lastRowIdByAccount[accountId] ?? 0
            var newestRowId = lastRowId

            for message in messages where message.rowId > lastRowId {
                newestRowId = max(newestRowId, message.rowId)
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard !Self.looksLikeForwardedNotification(text) else { continue }
                onInboundMessage?(accountId, message)
            }

            lastRowIdByAccount[accountId] = newestRowId
        }
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

    private func fetchNewMessagesLocked(recipient: String, accountId: UUID) -> [InboundIMessage]? {
        guard let chatIds = chatIdsLocked(for: recipient), !chatIds.isEmpty else { return nil }
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let lastRowId = lastRowIdByAccount[accountId] ?? 0
        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
        let sql = """
        SELECT m.ROWID, m.text, m.date
        FROM message m
        INNER JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders))
          AND m.ROWID > ?
          AND m.is_from_me = 0
          AND m.associated_message_type = 0
          AND m.text IS NOT NULL
          AND length(trim(m.text)) > 0
        ORDER BY m.ROWID ASC
        LIMIT 20
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
            let text = String(cString: sqlite3_column_text(statement, 1))
            let appleDate = sqlite3_column_int64(statement, 2)
            let date = Date(timeIntervalSinceReferenceDate: TimeInterval(appleDate) / 1_000_000_000)
            results.append(InboundIMessage(rowId: rowId, text: text, date: date))
        }
        return results
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
