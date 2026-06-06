import Foundation

enum AccountStatus: String, Codable, Sendable {
    case offline
    case needsAuth
    case reconnecting
    case online

    var displayName: String {
        switch self {
        case .offline: "Offline"
        case .needsAuth: "Требуется вход"
        case .reconnecting: "Переподключение"
        case .online: "Online"
        }
    }

    var indicator: String {
        switch self {
        case .online: "●"
        case .reconnecting: "◐"
        case .needsAuth: "○"
        case .offline: "○"
        }
    }
}
