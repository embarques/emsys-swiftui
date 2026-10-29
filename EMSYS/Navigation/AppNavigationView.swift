import SwiftUI

/// Desktop navigation groups workflows and preferences in a native sidebar.
struct AppNavigationView: View {
    @Environment(AuthenticationSession.self) private var session
    @Binding var selection: AppDestination?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "EMSYS").font(.title2.bold())
                    Text("navigation.workspace")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)

            List(selection: $selection) {
                Section("navigation.work") {
                    ForEach(AppDestination.primaryTabs.filter { $0 != .more }) { destination($0) }
                }
                Section("navigation.preferences") {
                    destination(.home)
                    destination(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("navigation.menu")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif

            if session.phase == .signedIn {
                account
            }
        }
    }

    private func destination(_ destination: AppDestination) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 14) {
                Image(systemName: destination.systemImageName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(AppStyle.Colors.accent.opacity(0.1), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title).font(.headline)
                    Text(destination.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
        .accessibilityIdentifier("navigation-\(destination.rawValue)")
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let name = session.user?.name, !name.isEmpty {
                        Text(verbatim: name).font(.subheadline.weight(.semibold))
                    } else {
                        Text("navigation.account").font(.subheadline.weight(.semibold))
                    }
                    if let branch = session.user?.branch?.name, !branch.isEmpty {
                        Text(verbatim: branch).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button { selection = .more } label: {
                Label("permissions.profile", systemImage: "person.crop.circle")
                    .font(.subheadline).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            Button { session.signOut() } label: {
                Label("auth.signOut", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}
