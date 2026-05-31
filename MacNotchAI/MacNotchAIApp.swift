import SwiftUI

@main
struct MacNotchAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu-bar icon is a custom NSStatusItem managed in AppDelegate (not a
        // MenuBarExtra) so a left-click can RESTORE a minimized session instead of
        // always opening the menu. See AppDelegate.setupStatusItem().
        Settings {
            SettingsView()
        }
    }
}
