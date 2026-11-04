import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    @Environment(AuthenticationSession.self) private var session
    @State private var poolPreference: InvoicePoolPreferenceModel?
    @State private var poolIssue = false

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
            if let poolPreference {
                Section("settings.invoicePool.title") {
                    @Bindable var poolPreference = poolPreference
                    LabeledContent("settings.invoicePool.threshold") {
                        TextField("settings.invoicePool.threshold", value: $poolPreference.threshold, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .disabled(poolPreference.isLoading)
                    }
                    if !(0...10_000).contains(poolPreference.threshold) {
                        Text("settings.invoicePool.invalid").foregroundStyle(.red)
                    }
                    Text("settings.invoicePool.hint").font(.caption).foregroundStyle(.secondary)
                    Button("settings.invoicePool.save") { Task { await poolPreference.save() } }
                        .disabled(!poolPreference.canSave)
                    if let issue = poolPreference.issue { Text(LocalizedStringKey(issue)).foregroundStyle(.red) }
                    if poolPreference.saved { Text("settings.invoicePool.saved").foregroundStyle(.secondary) }
                }
            }
            if poolIssue { Text("settings.invoicePool.loadError").foregroundStyle(.red) }
            Section {
                Text("settings.devicePreferences")
                    .font(AppStyle.Fonts.supporting)
                    .foregroundStyle(AppStyle.Colors.secondaryText)
            }
        }
        .task(id: session.contextID) {
            poolPreference = nil
            poolIssue = false
            guard session.canCreateInvoices || session.canCreateAssignedPickupInvoices else { return }
            do {
                let model = try await session.invoicePoolPreference()
                poolPreference = model
                await model.load()
            } catch { poolIssue = true }
        }
        .formStyle(.grouped)
        .navigationTitle(preferences.language.localizedString("navigation.settings"))
    }
}
