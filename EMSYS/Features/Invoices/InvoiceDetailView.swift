import SwiftUI

struct InvoiceDetailView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @State private var preview = InvoicePreviewModel()
    @Environment(SynchronizationState.self) private var synchronization
    @State private var model: InvoiceDetailModel
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case document(InvoiceDocumentModel)
        case editor(InvoiceItemEditorModel)
        case pending(PendingInvoiceEditsModel)

        var id: UUID {
            switch self {
            case .document(let model): model.id
            case .editor(let model): model.id
            case .pending(let model): model.id
            }
        }
    }

    init(model: InvoiceDetailModel) {
        _model = State(initialValue: model)
    }

    private var invoice: Invoice { model.invoice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
                if model.refreshFailed {
                    Text("invoices.refreshError")
                        .foregroundStyle(.secondary)
                }
                if let edit = model.pendingEdit {
                    Text(LocalizedStringKey("invoiceEdits.status.\(edit.state.rawValue)"))
                        .foregroundStyle(.secondary)
                }
                InvoiceDetailContent(invoice: invoice)
            }
            .frame(maxWidth: AppStyle.Layout.readableContentWidth, alignment: .leading)
            .padding(AppStyle.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("invoices.detailTitle")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.pendingEdit != nil {
                    Button {
                        let contextID = session.contextID
                        sheet = .pending(model.makePendingEdits(
                            isAuthorized: { session.contextID == contextID && session.canViewInvoices },
                            canEdit: { session.contextID == contextID && session.canUpdateInvoices }
                        ))
                    } label: {
                        Label("invoiceEdits.pendingTitle", systemImage: "tray.and.arrow.up")
                    }
                } else if session.canUpdateInvoices {
                    Button {
                        let contextID = session.contextID
                        sheet = .editor(model.makeItemEditor {
                            session.contextID == contextID && session.canUpdateInvoices
                        })
                    } label: {
                        Label("invoiceEdits.editorTitle", systemImage: "square.and.pencil")
                    }
                }
                if session.canPrintInvoices {
                    Button {
                        let contextID = session.contextID
                        let language = preferences.language.rawValue
                        let printedBy = session.user?.email ?? session.user?.name ?? ""
                        preview.generate(isAuthorized: { session.contextID == contextID && session.canPrintInvoices }) {
                            try await model.localPrintDocument(language: language, printedBy: printedBy)
                        }
                    } label: {
                        Label("documents.print", systemImage: "printer")
                    }
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("invoices.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                Menu {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("invoices.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                } label: {
                    Label("invoices.moreActions", systemImage: "ellipsis")
                }
            }
        }
        .sheet(item: $sheet, onDismiss: { Task { await model.reloadSavedInvoice() } }) { sheet in
            switch sheet {
            case .document(let model): InvoiceDocumentView(model: model)
            case .editor(let model): InvoiceItemEditorView(model: model)
            case .pending(let model): PendingInvoiceEditsView(model: model)
            }
        }
        .modifier(InvoicePreviewModifier(preview: preview))
        .onChange(of: session.contextID) { preview.cancel() }
        .task {
            await model.refresh()
            if session.canPrintInvoices { await model.preparePrinting() }
        }
        .onChange(of: synchronization.lastFinishedAt) {
            Task { await model.reloadSavedInvoice() }
        }
    }

}
