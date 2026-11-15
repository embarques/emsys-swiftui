import SwiftUI

extension View {
    /// Shows connection and synchronization messages above the screen content.
    func connectionStatus(showsSyncFailure: Bool = true) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ConnectionStatusView(showsSyncFailure: showsSyncFailure)
        }
    }
}

private struct ConnectionStatusView: View {
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization

    let showsSyncFailure: Bool

    /// Keeps connection feedback visible above scrollable feature content.
    var body: some View {
        VStack(spacing: 0) {
            // Show offline state before any synchronization feedback.
            if connection.status == .unavailable {
                Label("connection.offline", systemImage: "wifi.slash")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.Spacing.medium)
                    .background(.orange.opacity(0.18))
            }
            // Replace stale failure feedback while a new attempt is running.
            if synchronization.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("sync.running")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppStyle.Spacing.small)
            } else if showsSyncFailure, synchronization.failed, connection.status != .unavailable {
                let message: LocalizedStringKey = synchronization.requiresReview ? "sync.reviewRequired" : "sync.failed"
                MessagePanel(message: message, icon: "exclamationmark.triangle")
                    .padding(.horizontal, AppStyle.Spacing.medium)
                    .padding(.vertical, AppStyle.Spacing.small)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .combine)
    }
}
