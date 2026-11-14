import SwiftUI

extension View {
    func connectionStatus() -> some View {
        modifier(ConnectionStatusModifier())
    }
}

private struct ConnectionStatusModifier: ViewModifier {
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @State private var showsWarning = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            .toolbar {
                if synchronization.failed, !synchronization.isRunning, connection.status != .unavailable {
                    Button {
                        showsWarning = true
                    } label: {
                        Label("sync.warning", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .alert("sync.warning", isPresented: $showsWarning) {
                Button("documents.close", role: .cancel) { }
            } message: {
                Text(synchronization.requiresReview ? "sync.reviewRequired" : "sync.failed")
            }
    }
}

private struct ConnectionStatusView: View {
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
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .combine)
    }
}
