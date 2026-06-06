import Foundation

struct DailyStats: Codable, Sendable {
    var filtered: Int = 0
    var received: Int = 0
    var sent: Int = 0
    var errors: Int = 0

    mutating func recordFiltered() { filtered += 1 }
    mutating func recordReceived() { received += 1 }
    mutating func recordSent() { sent += 1 }
    mutating func recordError() { errors += 1 }

    init(filtered: Int = 0, received: Int = 0, sent: Int = 0, errors: Int = 0) {
        self.filtered = filtered
        self.received = received
        self.sent = sent
        self.errors = errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filtered = try container.decodeIfPresent(Int.self, forKey: .filtered) ?? 0
        received = try container.decodeIfPresent(Int.self, forKey: .received) ?? 0
        sent = try container.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        errors = try container.decodeIfPresent(Int.self, forKey: .errors) ?? 0
    }
}

struct AccountSnapshot: Identifiable, Sendable {
    let id: UUID
    let account: Account
    var status: AccountStatus
    var stats: DailyStats

    init(account: Account, status: AccountStatus, stats: DailyStats) {
        id = account.id
        self.account = account
        self.status = status
        self.stats = stats
    }
}
