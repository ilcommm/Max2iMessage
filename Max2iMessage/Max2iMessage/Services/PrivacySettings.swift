import Foundation

/// Global privacy mode: hides MAX UI, disables file logging and verbose diagnostics.
enum PrivacySettings {
    #if DEBUG
    static let isDeveloperBuild = true
    #else
    static let isDeveloperBuild = false
    #endif

    /// Effective privacy mode for the running build.
    static var isActive: Bool {
        #if DEBUG
        AppPreferencesStore.shared.privacyModeEnabled
        #else
        true
        #endif
    }

    static var canToggle: Bool {
        isDeveloperBuild
    }

    static var displayPrivacyModeEnabled: Bool {
        #if DEBUG
        AppPreferencesStore.shared.privacyModeEnabled
        #else
        true
        #endif
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var privacyModeEnabled: Bool

    static let `default` = AppPreferences(privacyModeEnabled: true)
}

@MainActor
@Observable
final class AppPreferencesStore {
    static let shared = AppPreferencesStore()

    private(set) var preferences: AppPreferences

    private init() {
        preferences = Persistence.shared.loadPreferences()
    }

    var privacyModeEnabled: Bool {
        get { preferences.privacyModeEnabled }
        set {
            guard PrivacySettings.canToggle else { return }
            preferences = AppPreferences(privacyModeEnabled: newValue)
            save()
        }
    }

    func save() {
        Persistence.shared.savePreferences(preferences)
    }
}
