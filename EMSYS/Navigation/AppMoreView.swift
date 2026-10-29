import SwiftUI

struct AppMoreView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    let synchronize: () async -> Void

    var body: some View {
        List {
            Section("navigation.workspace") {
                NavigationLink { HomeView() } label: {
                    Label(AppDestination.home.title, systemImage: AppDestination.home.systemImageName)
                }
                NavigationLink { SettingsView() } label: {
                    Label(AppDestination.settings.title, systemImage: AppDestination.settings.systemImageName)
                }
            }
            if session.canViewInvoices {
                Section("navigation.syncSection") {
                    Button { Task { await synchronize() } } label: {
                        HStack {
                            Label("sync.now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if synchronization.isRunning { ProgressView() }
                        }
                    }
                    .disabled(synchronization.isRunning || connection.status == .unavailable)
                    if let lastDownloadedAt = synchronization.lastDownloadedAt {
                        LabeledContent("navigation.lastSync") { Text(lastDownloadedAt, format: .dateTime) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("navigation.account") {
                if let name = session.user?.name, !name.isEmpty { Text(verbatim: name).font(.headline) }
                if let email = session.user?.email, !email.isEmpty { Text(verbatim: email).foregroundStyle(.secondary) }
                if let branch = session.user?.branch?.name, !branch.isEmpty {
                    Label(branch, systemImage: "building.2").foregroundStyle(.secondary)
                }
                if let role = session.permissions?.role.name {
                    LabeledContent("permissions.role", value: role)
                }
                PermissionSyncControls(isSyncing: session.isSyncingPermissions,
                    syncedAt: session.permissionsSyncedAt, issue: session.permissionsSyncIssue,
                    isOnline: connection.status != .unavailable) {
                        await session.syncPermissions()
                    }
                Button(role: .destructive) { session.signOut() } label: {
                    Label("auth.signOut", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle(AppDestination.more.title)
    }
}
