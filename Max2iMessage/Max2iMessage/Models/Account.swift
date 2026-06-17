import Foundation

enum ForwardDestination: String, Codable, CaseIterable, Sendable {
    case iMessage
    case email
    case both

    var label: String {
        switch self {
        case .iMessage: "iMessage"
        case .email: "Email"
        case .both: "iMessage и Email"
        }
    }
}

struct Account: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var forwardDestination: ForwardDestination
    var iMessageRecipient: String
    var emailRecipient: String
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
    var forwardDelaySeconds: Double
    var forwardNotificationOnly: Bool
    var iMessageReplyEnabled: Bool
    var iMessageReplyConfirmationEnabled: Bool
    var replyWindowMinutes: Double

    init(
        id: UUID,
        name: String,
        forwardDestination: ForwardDestination = .iMessage,
        iMessageRecipient: String,
        emailRecipient: String = "",
        contactIdentifier: String?,
        enabled: Bool,
        skipGroupChats: Bool,
        skipOwnMessages: Bool,
        skipMutedChats: Bool,
        forwardAttachmentsPlaceholder: Bool,
        verboseChatLogging: Bool = false,
        traceRealtimeLogging: Bool = true,
        muteProbeLogging: Bool = false,
        smartForwardEnabled: Bool = true,
        forwardDelaySeconds: Double = 1.5,
        forwardNotificationOnly: Bool = false,
        iMessageReplyEnabled: Bool = false,
        iMessageReplyConfirmationEnabled: Bool = false,
        replyWindowMinutes: Double = 10
    ) {
        self.id = id
        self.name = name
        self.forwardDestination = forwardDestination
        self.iMessageRecipient = iMessageRecipient
        self.emailRecipient = emailRecipient
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
        self.forwardDelaySeconds = forwardDelaySeconds
        self.forwardNotificationOnly = forwardNotificationOnly
        self.iMessageReplyEnabled = iMessageReplyEnabled
        self.iMessageReplyConfirmationEnabled = iMessageReplyConfirmationEnabled
        self.replyWindowMinutes = replyWindowMinutes
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
        forwardDestination = try container.decodeIfPresent(ForwardDestination.self, forKey: .forwardDestination) ?? .iMessage
        iMessageRecipient = try container.decode(String.self, forKey: .iMessageRecipient)
        emailRecipient = try container.decodeIfPresent(String.self, forKey: .emailRecipient) ?? ""
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
        forwardDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .forwardDelaySeconds) ?? 1.5
        forwardNotificationOnly = try container.decodeIfPresent(Bool.self, forKey: .forwardNotificationOnly) ?? false
        iMessageReplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .iMessageReplyEnabled) ?? false
        iMessageReplyConfirmationEnabled = try container.decodeIfPresent(Bool.self, forKey: .iMessageReplyConfirmationEnabled) ?? false
        replyWindowMinutes = try container.decodeIfPresent(Double.self, forKey: .replyWindowMinutes) ?? 10
    }

    var effectiveRecipient: String {
        iMessageRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveEmailRecipient: String {
        emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasConfiguredDestination: Bool {
        switch forwardDestination {
        case .iMessage:
            !effectiveRecipient.isEmpty
        case .email:
            !effectiveEmailRecipient.isEmpty
        case .both:
            !effectiveRecipient.isEmpty || !effectiveEmailRecipient.isEmpty
        }
    }

    var destinationSummary: String {
        switch forwardDestination {
        case .iMessage:
            effectiveRecipient
        case .email:
            effectiveEmailRecipient
        case .both:
            [effectiveRecipient, effectiveEmailRecipient].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    var supportsIMessageReply: Bool {
        iMessageReplyEnabled
            && (forwardDestination == .iMessage || forwardDestination == .both)
            && !effectiveRecipient.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, forwardDestination, iMessageRecipient, emailRecipient, contactIdentifier, enabled
        case skipGroupChats, skipOwnMessages, skipMutedChats, forwardAttachmentsPlaceholder
        case verboseChatLogging, traceRealtimeLogging, muteProbeLogging, smartForwardEnabled
        case forwardDelaySeconds, forwardNotificationOnly, iMessageReplyEnabled, iMessageReplyConfirmationEnabled, replyWindowMinutes
    }

    var effectiveVerboseChatLogging: Bool {
        !PrivacySettings.isActive && verboseChatLogging
    }

    var effectiveTraceRealtimeLogging: Bool {
        !PrivacySettings.isActive && traceRealtimeLogging
    }

    var effectiveMuteProbeLogging: Bool {
        !PrivacySettings.isActive && muteProbeLogging
    }
}
