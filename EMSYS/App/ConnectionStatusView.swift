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
            .sheet(isPresented: $showsWarning) {
                NavigationStack {
                    ScrollView {
                        if synchronization.failed, !synchronization.isRunning {
                            MessagePanel(message: synchronization.requiresReview ? "sync.reviewRequired" : "sync.failed",
                                         icon: "exclamationmark.triangle")
                                .padding()
                        }
                    }
                    .navigationTitle("sync.warning")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("documents.close") { showsWarning = false }
                        }
                    }
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #else
                .frame(minWidth: 380, minHeight: 200)
                #endif
            }
            .onChange(of: synchronization.failed) {
                if !synchronization.failed { showsWarning = false }
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
