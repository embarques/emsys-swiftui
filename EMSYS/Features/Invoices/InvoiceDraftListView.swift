import SwiftUI

struct InvoiceDraftListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SynchronizationState.self) private var synchronization
    @State var model: InvoiceDraftListModel
    @State private var editor: InvoiceDraftEditorModel?
    @State private var draftToDelete: InvoiceDraftSummary?

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable {
                    draftList
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .navigationTitle("drafts.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("documents.close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = model.editor() } label: { Label("drafts.new", systemImage: "plus") }
                        .disabled(!model.isAvailable || model.assignedOnly)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            .task { await model.load() }
            .onChange(of: synchronization.lastFinishedAt) { Task { await model.load() } }
            .modifier(InvoiceCreationPresentation(editor: $editor, onDismiss: { Task { await model.load() } }))
            .confirmationDialog("drafts.deletePrompt", isPresented: Binding(
                get: { draftToDelete != nil }, set: { if !$0 { draftToDelete = nil } }
            )) {
                if let draft = draftToDelete {
                    Button("drafts.delete", role: .destructive) { Task { await model.delete(draft) } }
                }
                Button("invoiceEdits.cancel", role: .cancel) { draftToDelete = nil }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var draftList: some View {
        VStack(spacing: 0) {
            if let issue = model.issue { Text(LocalizedStringKey(issue)).padding() }
            List(model.drafts) { draft in
                Button { editor = model.editor(draftID: draft.id) } label: {
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                        if draft.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("drafts.untitled").font(.headline)
                        } else {
                            Text(draft.senderName).font(.headline)
                        }
                        if !draft.receiverName.isEmpty { Text(draft.receiverName).foregroundStyle(.secondary) }
                        Text(draft.savedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        if draft.pendingAttachmentCount > 0 {
                            Label("invoiceAttachments.pending", systemImage: "paperclip.badge.ellipsis")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let state = draft.creationState {
                            Label(LocalizedStringKey(state.title), systemImage: state == .completed ? "checkmark.circle" : "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if draft.pendingAttachmentCount == 0 && (draft.creationState == nil || draft.creationState == .completed) {
                        Button("drafts.delete", role: .destructive) { draftToDelete = draft }
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    if draft.pendingAttachmentCount == 0 && (draft.creationState == nil || draft.creationState == .completed) {
                        Button("drafts.delete", role: .destructive) { draftToDelete = draft }
                            .tint(.red)
                    }
                }
            }
            .overlay {
                if model.drafts.isEmpty {
                    if model.isLoading { ProgressView() }
                    else { ContentUnavailableView("drafts.empty", systemImage: "doc.badge.plus") }
                }
            }
            HStack {
                Button("invoices.previous") { Task { await model.load(page: model.page - 1) } }
                    .disabled(model.page == 1 || model.isLoading)
                Spacer()
                Button("invoices.next") { Task { await model.load(page: model.page + 1) } }
                    .disabled(model.drafts.count < 40 || model.isLoading)
            }
            .padding()
        }
    }
}
