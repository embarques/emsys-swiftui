import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("settings.preferences") {
                Picker("settings.language", selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                Picker("settings.appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }
            Section {
                Text("settings.devicePreferences")
                    .font(AppStyle.Fonts.supporting)
                    .foregroundStyle(AppStyle.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(preferences.language.localizedString("navigation.settings"))
    }
}
