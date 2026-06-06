import Foundation

struct BridgeEvent: Sendable {
    enum EventType: String, Sendable {
        case monitorReady
        case authReady
        case chatsSynced
        case authCheck
        case newMessage
        case wsClosed
        case wsOpen
        case domActivity
        case heartbeat
        case messageTraffic
        case chatRaw
        case muteProbe
        case messageObserved
        case unknown
    }

    let type: EventType
    let payload: [String: Any]
}

enum MessageMonitorParser {
    private static let groupTypes: Set<String> = ["GROUP", "CHANNEL", "CHAT"]

    static func parse(body: [String: Any]) -> BridgeEvent? {
        guard let typeRaw = body["type"] as? String else { return nil }
        let payload = body["payload"] as? [String: Any] ?? [:]
        let type: BridgeEvent.EventType = switch typeRaw {
        case "monitor_ready": .monitorReady
        case "auth_ready": .authReady
        case "chats_synced": .chatsSynced
        case "auth_check": .authCheck
        case "new_message": .newMessage
        case "ws_closed": .wsClosed
        case "ws_open": .wsOpen
        case "dom_activity": .domActivity
        case "heartbeat": .heartbeat
        case "message_traffic": .messageTraffic
        case "chat_raw": .chatRaw
        case "message_observed": .messageObserved
        case "mute_probe": .muteProbe
        default: .unknown
        }
        return BridgeEvent(type: type, payload: payload)
    }

    static func makeMessage(from payload: [String: Any]) -> MaxMessage? {
        guard let messageId = stringValue(payload["messageId"]),
              let chatId = stringValue(payload["chatId"]) else { return nil }

        let senderId = stringValue(payload["senderId"]) ?? "unknown"
        let senderName = stringValue(payload["senderName"]) ?? ""
        let text = stringValue(payload["text"]) ?? ""
        let timestamp = Int64(stringValue(payload["timestamp"]) ?? "0") ?? 0
        let chatType = stringValue(payload["chatType"]) ?? ""
        let hasAttachment = payload["hasAttachment"] as? Bool ?? false
        let isGroup = groupTypes.contains(chatType.uppercased())
        let isMuted = payload["isMutedChat"] as? Bool ?? false
        let chatTypeKnown = payload["chatTypeKnown"] as? Bool ?? false
        let chatMuteKnown = payload["chatMuteKnown"] as? Bool ?? false
        let chatTitle = stringValue(payload["chatTitle"]) ?? ""

        return MaxMessage(
            id: messageId,
            chatId: chatId,
            senderId: senderId,
            senderName: senderName,
            text: text,
            timestamp: timestamp,
            isGroupChat: isGroup,
            isMutedChat: isMuted,
            chatTypeKnown: chatTypeKnown,
            chatMuteKnown: chatMuteKnown,
            hasAttachment: hasAttachment,
            chatTitle: chatTitle
        )
    }

    static func isOwnMessage(payload: [String: Any], myUserId: String?) -> Bool {
        guard let myUserId, let senderId = stringValue(payload["senderId"]) else { return false }
        return senderId == myUserId
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String where !s.isEmpty: s
        case let n as Int: String(n)
        case let n as Int64: String(n)
        case let n as Double: String(Int64(n))
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
}
