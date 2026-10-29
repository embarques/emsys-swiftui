import SwiftUI

struct InvoiceItemEditorView: View {
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(\.dismiss) private var dismiss
    @State var model: InvoiceItemEditorModel
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if model.mayEdit {
                    editorForm
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("invoiceEdits.editorTitle")
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") {
                        if model.hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("invoiceEdits.save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
            .confirmationDialog("invoiceEdits.discardPrompt", isPresented: $confirmsDiscard) {
                Button("invoiceEdits.discard", role: .destructive) { dismiss() }
                Button("invoiceEdits.continueEditing", role: .cancel) { }
            }
            .task { await model.load() }
            .onChange(of: model.didSave) {
                if model.didSave {
                    if model.queuedEdit != nil { synchronization.requestUpload() }
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var editorForm: some View {
        Form {
            if model.isLoading { ProgressView() }
            if let issue = model.issue { Text(LocalizedStringKey(issue)) }
            Section {
                ForEach(model.items) { item in
                    TextField("invoiceEdits.description", text: Binding(
                        get: { model.items.first { $0.id == item.id }?.name ?? "" },
                        set: { model.setName($0, itemID: item.id) }
                    ), axis: .vertical)
                }
            } footer: {
                Text("invoiceEdits.saveHint")
            }
            .disabled(model.isSaving)
            if model.items.isEmpty && !model.isLoading {
                Button("auth.retry") { Task { await model.load() } }
            }
        }
    }

}
