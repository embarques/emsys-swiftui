import SwiftUI

struct ConnectionStatusView: View {
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization

    var body: some View {
        VStack(spacing: 0) {
            if connection.status == .unavailable {
                Label("connection.offline", systemImage: "wifi.slash")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.Spacing.medium)
                    .background(.orange.opacity(0.18))
            }
            if synchronization.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("sync.running")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppStyle.Spacing.small)
            } else if synchronization.failed, connection.status != .unavailable {
                Label("sync.failed", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.Spacing.small)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
