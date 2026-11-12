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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection = InvoiceSplitSelection()
    #else
    @State private var selectedInvoiceID: String?
    #endif
    @State private var localInvoiceToDelete: LocalInvoiceListEntry?
    @State private var showsLocalDeleteError = false
    @State private var creation: InvoiceDraftEditorModel?

    private enum Sheet: Identifiable {
        case pending(PendingInvoiceEditsModel)
        case drafts(InvoiceDraftListModel)
        case pool(InvoicePoolModel)
        case document(InvoiceDocumentModel)
        case filters
        var id: String {
            switch self {
            case .pending(let model): model.id.uuidString
            case .drafts(let model): model.id.uuidString
            case .pool(let model): model.id.uuidString
            case .document(let model): model.id.uuidString
            case .filters: "filters"
            }
        }
    }

    private var online: Bool { connection.status != .unavailable }

    private var usesSidebarRows: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    private var selectedInvoice: String? {
        #if os(iOS)
        selection.detail?.invoice.id
        #else
        selectedInvoiceID
        #endif
    }

    private var usesInlineDirectoryActions: Bool {
        #if os(iOS)
        usesSidebarRows && UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    var body: some View {
        navigation
            .task(id: session.contextID) { await prepare() }
    }

    @ViewBuilder
    private var navigation: some View {
        #if os(iOS)
        invoiceSplitView
            .toolbar(removing: usesInlineDirectoryActions ? .sidebarToggle : nil)
        #else
        directory
            .navigationDestination(item: $selectedInvoiceID) { id in
                if let model, let invoice = (model.localEntries.compactMap(\.invoice) + model.invoices).first(where: { $0.id == id }) {
                    InvoiceDetailView(model: model.detail(for: invoice))
                }
            }
        #endif
    }

    #if os(iOS)
    private var invoiceSplitView: some View {
        NavigationSplitView(preferredCompactColumn: $selection.compactColumn) {
            directory
                .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            if let selectedDetail = selection.detail {
                InvoiceDetailView(model: selectedDetail)
                    .id(selectedDetail.invoice.id)
                    .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            } else {
                ContentUnavailableView("invoices.selectInvoice", systemImage: "doc.text")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif

    private var directory: some View {
        ZStack {
            if let model {
                InvoiceDirectoryView(query: $query, invoices: model.invoices, localEntries: model.localEntries,
                    usesSidebarRows: usesSidebarRows, showsSidebarHeading: !usesInlineDirectoryActions,
                    selectedInvoiceID: selectedInvoice,
                    openLocal: { creation = draftListModel(model).editor(draftID: $0.draftID) },
                    deleteLocal: synchronization.isRunning ? nil : { localInvoiceToDelete = $0 },
                    outstandingBalance: model.outstandingBalance, isLoading: model.isLoading,
                    isDownloaded: model.isShowingDownloaded, hasMore: model.hasMore, issue: model.issue,
                    showFilters: { sheet = .filters }, open: { open($0, in: model) },
                    printInvoice: session.canPrintInvoices ? { printInvoice($0, model: model) } : nil,
                    more: { await model.loadMore(online: online) },
                    retry: { await model.retry(online: online) },
                    refresh: { await model.request(query: query, online: online).value })
                .task { await model.refreshInvoicePoolSummary() }
                .toolbar {
                    if !usesInlineDirectoryActions {
                        createButton(model)
                        if !usesSidebarRows {
                            Button {
                                model.request(query: query, online: online)
                            } label: { Label("invoices.refresh", systemImage: "arrow.clockwise") }
                        }
                        directoryMenu(model)
                    }
                }
            } else {
                InvoiceDirectoryView(query: $query, invoices: [], usesSidebarRows: usesSidebarRows,
                    showsSidebarHeading: !usesInlineDirectoryActions, outstandingBalance: 0,
                    isLoading: !loader.failed, isDownloaded: !online, hasMore: false,
                    issue: loader.failed ? "invoices.unavailable" : nil,
                    showFilters: {}, open: { _ in }, printInvoice: nil, more: {},
                    retry: { await prepare() }, refresh: { await prepare() })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.canCreateInvoices, let model {
                InvoicePoolWarningView(issue: model.invoicePoolIssue, count: model.availableReservations,
                                       threshold: model.poolThreshold) {
                    sheet = .pool(draftListModel(model).pool())
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if usesInlineDirectoryActions {
                HStack(spacing: 8) {
                    Text("navigation.invoices")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let model {
                        createButton(model).labelStyle(.iconOnly)
                        directoryMenu(model, iconOnly: true)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.background)
            }
        }
        .confirmationDialog("invoiceList.deleteLocalTitle", isPresented: Binding(
            get: { localInvoiceToDelete != nil },
            set: { if !$0 { localInvoiceToDelete = nil } }
        ), titleVisibility: .visible, presenting: localInvoiceToDelete) { entry in
            Button("drafts.delete", role: .destructive) {
                let contextID = session.contextID
                Task {
                    guard let model, session.contextID == contextID, session.canViewInvoices else { return }
                    do {
                        try await synchronization.deleteLocalInvoice {
                            try await model.deleteLocalInvoice(entry)
                        }
                    } catch {
                        if session.contextID == contextID { showsLocalDeleteError = true }
                    }
                }
            }
            Button("invoiceEdits.cancel", role: .cancel) { }
        } message: { _ in
            Text("invoiceList.deleteLocalMessage")
        }
        .alert("invoiceList.deleteLocalError", isPresented: $showsLocalDeleteError) {
            Button("documents.close", role: .cancel) { }
        }
        .modifier(InvoicePreviewModifier(preview: preview))
        .modifier(InvoiceCreationPresentation(editor: $creation, onDismiss: {
            model?.request(query: query, online: online)
            Task { await model?.refreshInvoicePoolSummary() }
        }))
        .onChange(of: session.contextID) { preview.cancel() }
        .navigationTitle(usesSidebarRows ? "" : preferences.language.localizedString("navigation.invoices"))
        .sheet(item: $sheet, onDismiss: { model?.request(query: query, online: online); Task { await model?.refreshInvoicePoolSummary() } }) { sheet in
            switch sheet {
            case .pending(let model): PendingInvoiceEditsView(model: model)
            case .drafts(let model): InvoiceDraftListView(model: model)
            case .pool(let model): InvoicePoolView(model: model)
            case .document(let model): InvoiceDocumentView(model: model)
            case .filters: InvoiceListFiltersView(query: query) { query = $0 }
            }
        }
        .onChange(of: query) {
            model?.request(query: query, online: online, debounce: true)
        }
        .onChange(of: connection.status) {
            model?.request(query: query, online: online)
            if online, session.canPrintInvoices { model?.preparePrinting() }
        }
        .onChange(of: synchronization.lastFinishedAt) {
            model?.request(query: query, online: online)
            Task { await model?.refreshInvoicePoolSummary() }
        }
    }

    @ViewBuilder
    private func createButton(_ model: InvoiceListModel) -> some View {
        if session.canCreateInvoices {
            Button { creation = draftListModel(model).editor() } label: {
                Label("invoiceCreation.title", systemImage: "plus")
            }
            .disabled((model.availableReservations ?? 0) == 0)
        }
    }

    private func directoryMenu(_ model: InvoiceListModel, iconOnly: Bool = false) -> some View {
        Menu {
            if session.canCreateInvoices {
                Button { sheet = .pool(draftListModel(model).pool()) } label: {
                    Label("invoicePool.title", systemImage: "number")
                }
            }
            Button { sheet = .drafts(draftListModel(model)) } label: {
                Label("drafts.title", systemImage: "doc.badge.plus")
            }
            Button {
                let contextID = session.contextID
                sheet = .pending(model.pendingEdits(
                    isAuthorized: { session.contextID == contextID && session.canViewInvoices },
                    canEdit: { session.contextID == contextID && session.canUpdateInvoices }))
            } label: { Label("invoiceEdits.pendingTitle", systemImage: "tray.and.arrow.up") }
            Button {
                model.request(query: query, online: online)
            } label: { Label("invoices.refresh", systemImage: "arrow.clockwise") }
        } label: {
            if iconOnly {
                Label("invoiceList.actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            } else {
                Label("invoiceList.actions", systemImage: "ellipsis.circle")
            }
        }
    }

    private func open(_ invoice: Invoice, in model: InvoiceListModel) {
        #if os(iOS)
        selection.open(invoice, in: model)
        #else
        selectedInvoiceID = invoice.id
        #endif
    }

    private func draftListModel(_ model: InvoiceListModel) -> InvoiceDraftListModel {
        let contextID = session.contextID
        return model.drafts(canGeneratePool: { session.contextID == contextID && session.permissions?.contains("canGenerateOwnInvoicePool", resourceType: "invoice_pool_self") == true }, canViewItemCatalog: {
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
        }, defaultPaymentRegion: session.user?.branch?.code, financialPermission: { permission in
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
        #if os(iOS)
        selection = InvoiceSplitSelection()
        #else
        selectedInvoiceID = nil
        #endif
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

#if os(iOS)
@MainActor
struct InvoiceSplitSelection {
    private(set) var detail: InvoiceDetailModel?
    var compactColumn: NavigationSplitViewColumn = .sidebar

    mutating func open(_ invoice: Invoice, in list: InvoiceListModel) {
        // Keep the active detail alive independently of filtering and pagination.
        if detail?.invoice.id != invoice.id {
            detail = list.detail(for: invoice)
        }
        compactColumn = .detail
    }
}
#endif
