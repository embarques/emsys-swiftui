import SwiftUI

struct PendingInvoiceEditsView: View {
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(NetworkConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State var model: PendingInvoiceEditsModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.failed { Text("invoiceEdits.loadFailed").padding() }
                if model.isAvailable {
                    List(model.edits) { edit in
                        NavigationLink {
                            InvoiceEditReviewView(model: model.review(edit))
                        } label: {
                            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                                if let number = edit.invoiceNumber { Text(number).font(.headline) }
                                Text(LocalizedStringKey("invoiceEdits.status.\(edit.state.rawValue)"))
                                    .foregroundStyle(.secondary)
                                Text(edit.createdAt, format: .dateTime).font(.caption)
                            }
                        }
                    }
                    .overlay {
                        if model.edits.isEmpty {
                            if model.isLoading { ProgressView() }
                            else { ContentUnavailableView("invoiceEdits.empty", systemImage: "checkmark.circle") }
                        }
                    }
                    HStack {
                        Button("invoices.previous") { Task { await model.load(page: model.page - 1) } }
                            .disabled(model.page == 1 || model.isLoading)
                        Spacer()
                        Button("invoices.next") { Task { await model.load(page: model.page + 1) } }
                            .disabled(model.edits.count < 40 || model.isLoading)
                    }
                    .padding()
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .navigationTitle("invoiceEdits.pendingTitle")
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            .toolbar {
                Button("sync.now") { synchronization.requestUpload() }
                    .disabled(synchronization.isRunning || connection.status == .unavailable || !model.isAvailable)
                Button("documents.close") { dismiss() }
            }
            .task { await model.load() }
            .onChange(of: synchronization.lastFinishedAt) { Task { await model.load() } }
            .onChange(of: synchronization.requestedUploadVersion) { Task { await model.load() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }
}
