import SwiftUI

struct InvoiceListView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(NetworkConnection.self) private var connection
    @State private var loader = InvoiceListLoader()
    private var model: InvoiceListModel? { loader.model }
    @State private var query = InvoiceListQuery()
    @State private var sheet: Sheet?
    @State private var preview = InvoicePreviewModel()
    @State private var selectedInvoiceID: String?
    @State private var creation: InvoiceDraftEditorModel?

    private enum Sheet: Identifiable {
        case pending(PendingInvoiceEditsModel)
        case drafts(InvoiceDraftListModel)
        case document(InvoiceDocumentModel)
        case filters
        var id: String {
            switch self {
            case .pending(let model): model.id.uuidString
            case .drafts(let model): model.id.uuidString
            case .document(let model): model.id.uuidString
            case .filters: "filters"
            }
        }
    }

    private var online: Bool { connection.status != .unavailable }

    var body: some View {
        ZStack {
            if let model {
                InvoiceDirectoryView(query: $query, invoices: model.invoices,
                    outstandingBalance: model.outstandingBalance, isLoading: model.isLoading,
                    isDownloaded: model.isShowingDownloaded, hasMore: model.hasMore, issue: model.issue,
                    showFilters: { sheet = .filters }, open: { selectedInvoiceID = $0.id },
                    printInvoice: session.canPrintInvoices ? { printInvoice($0, model: model) } : nil,
                    more: { await model.loadMore(online: online) },
                    retry: { await model.retry(online: online) },
                    refresh: { await model.request(query: query, online: online).value })
                .toolbar {
                    if session.canCreateInvoices {
                        Button { creation = draftListModel(model).editor() } label: {
                            Label("invoiceCreation.title", systemImage: "plus")
                        }
                    }
                    Button {
                        model.request(query: query, online: online)
                    } label: { Label("invoices.refresh", systemImage: "arrow.clockwise") }
                    Menu {
                        Button {
                            sheet = .drafts(draftListModel(model))
                        } label: { Label("drafts.title", systemImage: "doc.badge.plus") }
                        Button {
                            let contextID = session.contextID
                            sheet = .pending(model.pendingEdits(
                                isAuthorized: { session.contextID == contextID && session.canViewInvoices },
                                canEdit: { session.contextID == contextID && session.canUpdateInvoices }))
                        } label: { Label("invoiceEdits.pendingTitle", systemImage: "tray.and.arrow.up") }
                        Button {
                            model.request(query: query, online: online)
                        } label: { Label("invoices.refresh", systemImage: "arrow.clockwise") }
                    } label: { Label("invoiceList.actions", systemImage: "ellipsis.circle") }
                }
            } else {
                InvoiceDirectoryView(query: $query, invoices: [], outstandingBalance: 0,
                    isLoading: !loader.failed, isDownloaded: !online, hasMore: false,
                    issue: loader.failed ? "invoices.unavailable" : nil,
                    showFilters: {}, open: { _ in }, printInvoice: nil, more: {},
                    retry: { await prepare() }, refresh: { await prepare() })
            }
        }
        .modifier(InvoicePreviewModifier(preview: preview))
        .modifier(InvoiceCreationPresentation(editor: $creation))
        .onChange(of: session.contextID) { preview.cancel() }
        .navigationTitle(preferences.language.localizedString("navigation.invoices"))
        .navigationDestination(item: $selectedInvoiceID) { id in
            if let model, let invoice = model.invoices.first(where: { $0.id == id }) {
                InvoiceDetailView(model: model.detail(for: invoice))
            }
        }
        .sheet(item: $sheet, onDismiss: { model?.request(query: query, online: online) }) { sheet in
            switch sheet {
            case .pending(let model): PendingInvoiceEditsView(model: model)
            case .drafts(let model): InvoiceDraftListView(model: model)
            case .document(let model): InvoiceDocumentView(model: model)
            case .filters: InvoiceListFiltersView(query: query) { query = $0 }
            }
        }
        .task(id: session.contextID) { await prepare() }
        .onChange(of: query) {
            model?.request(query: query, online: online, debounce: true)
        }
        .onChange(of: connection.status) {
            model?.request(query: query, online: online)
            if online, session.canPrintInvoices { model?.preparePrinting() }
        }
        .onChange(of: synchronization.lastFinishedAt) {
            model?.request(query: query, online: online)
        }
    }

    private func draftListModel(_ model: InvoiceListModel) -> InvoiceDraftListModel {
        let contextID = session.contextID
        return model.drafts(canViewItemCatalog: {
            session.contextID == contextID && session.canViewInvoices
                && session.permissions?.contains("canViewSettings", resourceType: "settings") == true
        }, canViewCustomers: {
            session.contextID == contextID && session.canViewCustomers
        }, canReviewPolicies: {
            session.contextID == contextID && session.canReviewInvoicePolicies
        }, canViewContainers: {
            session.contextID == contextID && session.canViewContainers
        }, canViewAssignments: { permission in
            session.contextID == contextID && session.canViewInvoices
                && session.permissions?.contains(permission.name, resourceType: permission.resourceType) == true
        }, canReviewPayments: {
            session.contextID == contextID && session.canViewInvoices
                && session.permissions?.contains("canViewIncomeStatement", resourceType: "income_statement") == true
        }, currentBranchID: {
            session.contextID == contextID ? session.user?.branch?.id : nil
        }, financialPermission: { permission in
            session.contextID == contextID && session.canViewInvoices && permission.isGranted(by: session.permissions)
        }) {
            session.contextID == contextID && session.canViewInvoices
        }
    }

    private func printInvoice(_ invoice: Invoice, model: InvoiceListModel) {
        let contextID = session.contextID
        let language = preferences.language.rawValue
        let printedBy = session.user?.email ?? session.user?.name ?? ""
        preview.generate(isAuthorized: { session.contextID == contextID && session.canPrintInvoices }) {
            try await model.localPrintDocument(for: invoice, language: language, printedBy: printedBy)
        }
    }

    private func prepare() async {
        selectedInvoiceID = nil
        sheet = nil
        creation = nil
        await loader.prepare {
            let access = try await session.invoiceAccess()
            try Task.checkCancellation()
            return InvoiceListModel(client: access.client, store: access.store)
        }
        model?.request(query: query, online: online)
        if online, session.canPrintInvoices { model?.preparePrinting() }
    }
}
