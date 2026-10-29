import SwiftUI

struct InvoiceEditReviewView: View {
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(NetworkConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State var model: InvoiceEditReviewModel
    @State private var confirmsServerCopy = false

    var body: some View {
        Form {
            if model.isAvailable {
                Section {
                    Text(LocalizedStringKey("invoiceEdits.status.\(model.edit.state.rawValue)"))
                    if let issue = model.issue { Text(LocalizedStringKey(issue)) }
                    if model.isLoading || model.isResolving { ProgressView() }
                }
                ForEach(model.edit.changes, id: \.itemID) { change in
                    Section {
                        LabeledContent("invoiceEdits.before", value: change.originalName ?? "—")
                        LabeledContent("invoiceEdits.local", value: change.updatedName)
                        if model.edit.state == .needsReview {
                            LabeledContent("invoiceEdits.server", value: model.serverName(itemID: change.itemID) ?? "—")
                        }
                    }
                }
                if model.edit.state == .needsReview {
                    Section {
                        Button("invoiceEdits.keepLocal") { Task { await model.resolve(keepLocalNames: true) } }
                            .disabled(!model.canKeepLocal)
                        Button("invoiceEdits.useServer", role: .destructive) { confirmsServerCopy = true }
                            .disabled(!model.canResolve)
                        Button("invoiceEdits.refreshReview") {
                            Task { await model.load(allowNetwork: connection.status != .unavailable) }
                        }
                        .disabled(model.isLoading || model.isResolving)
                    } footer: {
                        Text("invoiceEdits.reviewHint")
                    }
                } else {
                    Button("sync.now") { synchronization.requestUpload() }
                        .disabled(synchronization.isRunning || connection.status == .unavailable)
                }
            } else {
                Text("auth.unavailable")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("invoiceEdits.reviewTitle")
        .confirmationDialog("invoiceEdits.serverChoicePrompt", isPresented: $confirmsServerCopy) {
            Button("invoiceEdits.useServer", role: .destructive) { Task { await model.resolve(keepLocalNames: false) } }
            Button("invoiceEdits.cancel", role: .cancel) { }
        }
        .task { await model.load(allowNetwork: connection.status != .unavailable) }
        .onChange(of: synchronization.lastFinishedAt) {
            Task { await model.load(allowNetwork: connection.status != .unavailable) }
        }
        .onChange(of: model.didResolve) {
            if model.didResolve {
                synchronization.requestUpload()
                dismiss()
            }
        }
    }
}
