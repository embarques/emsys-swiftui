import SwiftUI

/// Shows account-wide connection and synchronization feedback in the invoice directory.
struct ConnectionStatusView: View {
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization

    /// Inserts a scrollable row only while there is a status to display.
    var body: some View {
        // Offline, running and failure all share the same position above the directory content.
        let offline = connection.status == .unavailable
        if offline || synchronization.isRunning || synchronization.failed {
            VStack(spacing: AppStyle.Spacing.small) {
                // Surface offline status even if an in-flight sync has yet to stop.
                if offline {
                    Label("connection.offline", systemImage: "wifi.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppStyle.Spacing.medium)
                        .background(.orange.opacity(0.18), in: .rect(cornerRadius: 14))
                }
                // Hide stale failure feedback during a retry or while offline.
                if synchronization.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("sync.running")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.Spacing.small)
                } else if synchronization.failed && !offline {
                    let message: LocalizedStringKey = synchronization.requiresReview ? "sync.reviewRequired" : "sync.failed"
                    MessagePanel(message: message, icon: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            .padding(.bottom, AppStyle.Spacing.small)
            .accessibilityElement(children: .combine)
        }
    }
}
