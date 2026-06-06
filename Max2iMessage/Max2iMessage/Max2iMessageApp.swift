import SwiftUI

@main
struct Max2iMessageApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Max2iMessage", systemImage: "message.badge") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Настройки Max2iMessage", id: "settings") {
            AccountSettingsView()
                .environment(appState)
        }
        .defaultSize(width: 680, height: 560)

        Window("Вход в MAX", id: "auth") {
            AuthWindowView()
                .environment(appState)
        }
        .defaultSize(width: 900, height: 700)
    }
}
