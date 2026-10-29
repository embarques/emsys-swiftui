import SwiftUI

struct PermissionSyncControls: View {
    let isSyncing: Bool
    let syncedAt: Date?
    let issue: String?
    let isOnline: Bool
    let sync: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { Task { await sync() } } label: {
                HStack {
                    Label("permissions.sync", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing { ProgressView() }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(isSyncing || !isOnline)
            .accessibilityIdentifier("sync-permissions")
            if let syncedAt {
                LabeledContent("permissions.lastSync") { Text(syncedAt, format: .dateTime) }
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("permissions.lastSyncUnknown").font(.caption).foregroundStyle(.secondary)
            }
            Text("permissions.localHint").font(.caption).foregroundStyle(.secondary)
            if let issue {
                Label(LocalizedStringKey(issue), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("permissions-sync-error")
            }
        }
        .padding(.vertical, 4)
    }
}
