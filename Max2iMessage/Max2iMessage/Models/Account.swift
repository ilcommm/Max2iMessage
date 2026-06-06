import Foundation

struct Account: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var iMessageRecipient: String
    var contactIdentifier: String?
    var enabled: Bool
    var skipGroupChats: Bool
    var skipOwnMessages: Bool
    var skipMutedChats: Bool
    var forwardAttachmentsPlaceholder: Bool
    var verboseChatLogging: Bool
    var traceRealtimeLogging: Bool
    var muteProbeLogging: Bool
    var smartForwardEnabled: Bool

    init(
        id: UUID,
        name: String,
        iMessageRecipient: String,
        contactIdentifier: String?,
        enabled: Bool,
        skipGroupChats: Bool,
        skipOwnMessages: Bool,
        skipMutedChats: Bool,
        forwardAttachmentsPlaceholder: Bool,
        verboseChatLogging: Bool = false,
        traceRealtimeLogging: Bool = true,
        muteProbeLogging: Bool = false,
        smartForwardEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.iMessageRecipient = iMessageRecipient
        self.contactIdentifier = contactIdentifier
        self.enabled = enabled
        self.skipGroupChats = skipGroupChats
        self.skipOwnMessages = skipOwnMessages
        self.skipMutedChats = skipMutedChats
        self.forwardAttachmentsPlaceholder = forwardAttachmentsPlaceholder
        self.verboseChatLogging = verboseChatLogging
        self.traceRealtimeLogging = traceRealtimeLogging
        self.muteProbeLogging = muteProbeLogging
        self.smartForwardEnabled = smartForwardEnabled
    }

    static func makeDefault() -> Account {
        Account(
            id: UUID(),
            name: "Основной",
            iMessageRecipient: "",
            contactIdentifier: nil,
            enabled: true,
            skipGroupChats: false,
            skipOwnMessages: true,
            skipMutedChats: true,
            forwardAttachmentsPlaceholder: true
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iMessageRecipient = try container.decode(String.self, forKey: .iMessageRecipient)
        contactIdentifier = try container.decodeIfPresent(String.self, forKey: .contactIdentifier)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        skipGroupChats = try container.decode(Bool.self, forKey: .skipGroupChats)
        skipOwnMessages = try container.decode(Bool.self, forKey: .skipOwnMessages)
        skipMutedChats = try container.decodeIfPresent(Bool.self, forKey: .skipMutedChats) ?? true
        forwardAttachmentsPlaceholder = try container.decode(Bool.self, forKey: .forwardAttachmentsPlaceholder)
        verboseChatLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseChatLogging) ?? false
        traceRealtimeLogging = try container.decodeIfPresent(Bool.self, forKey: .traceRealtimeLogging) ?? true
        muteProbeLogging = try container.decodeIfPresent(Bool.self, forKey: .muteProbeLogging) ?? false
        smartForwardEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartForwardEnabled) ?? true
    }

    var effectiveRecipient: String {
        iMessageRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iMessageRecipient, contactIdentifier, enabled
        case skipGroupChats, skipOwnMessages, skipMutedChats, forwardAttachmentsPlaceholder
        case verboseChatLogging, traceRealtimeLogging, muteProbeLogging, smartForwardEnabled
    }
}
