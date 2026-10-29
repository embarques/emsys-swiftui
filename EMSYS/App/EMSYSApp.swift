import SwiftUI

@main
struct EMSYSApp: App {
    @State private var preferences = AppPreferences()
    @State private var session = AuthenticationSession()
    @State private var connection = NetworkConnection()
    @State private var synchronization = SynchronizationState()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .appPreferences(preferences)
                .environment(session)
                .environment(connection)
                .environment(synchronization)
                .task {
                    // Unit tests inject their own transport and do not contact
                    // Firebase or the live API through application startup.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    session.start()
                    connection.start()
                }
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .appPreferences(preferences)
                .frame(minWidth: 420, minHeight: 240)
        }
        #endif
    }
}

private extension View {
    func appPreferences(_ preferences: AppPreferences) -> some View {
        environment(preferences)
            .environment(\.locale, preferences.language.locale)
            .preferredColorScheme(preferences.appearance.colorScheme)
    }
}
