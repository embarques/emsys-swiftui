import Foundation
import Observation

@MainActor
@Observable
final class InvoiceListViewModel {
    private(set) var availableReservations: Int?
    private(set) var poolThreshold = 10
    private(set) var invoicePoolIssue: String?

    /// Refreshes the count and threshold for the current invoice reservation pool.
    func refreshInvoicePoolSummary() async {
        do {
            let count = try await store.availableInvoiceReservationCount()
            let threshold = try await store.invoicePoolThreshold()
            guard !Task.isCancelled else { return }
            availableReservations = count
            poolThreshold = threshold
            invoicePoolIssue = nil
        } catch {
            availableReservations = nil
            invoicePoolIssue = "invoicePool.loadError"
        }
    }

    private(set) var localEntries: [LocalInvoiceListEntry] = []
    private(set) var invoices: [Invoice] = []
    private(set) var page = 0
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var hasMore = true
    private(set) var isShowingDownloaded = false
    private(set) var outstandingBalance = Decimal.zero
    private(set) var query = InvoiceListQuery()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var printPreparation: Task<Void, Never>?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let repository: InvoiceDirectoryRepository

    /// Sets up the directory and its tenant-scoped data dependencies.
    init(client: APIClient, store: InvoiceStore) {
        self.client = client
        self.store = store
        repository = InvoiceDirectoryRepository(client: client, store: store)
    }

    func deleteLocalInvoice(_ entry: LocalInvoiceListEntry) async throws {
        try await store.deleteOfflineInvoice(id: entry.id, draftID: entry.draftID)
        localEntries.removeAll { $0.id == entry.id }
    }

    /// The request belongs to the directory, not a transient navigation task.
    /// A new query cancels its predecessor; the API client retains session checks.
    @discardableResult
    func request(query: InvoiceListQuery, online: Bool, debounce: Bool = false) -> Task<Void, Never> {
        requestTask?.cancel()
        let task = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                await self?.load(query: query, online: online)
            } catch { /* A newer query replaces this request. */ }
        }
        requestTask = task
        return task
    }

    func preparePrinting() {
        guard printPreparation == nil else { return }
        printPreparation = Task {
            do { try await InvoiceLocalPrinting.prepare(client: client, store: store) }
            catch {
                // Keep the directory usable when the printing profile cannot be prepared.
                printPreparation = nil
                InvoiceLocalPrinting.logPreparationFailure(error)
            }
        }
    }

    func localPrintDocument(for invoice: Invoice, language: String, printedBy: String) async throws -> InvoiceDocument {
        // A background refresh must not delay printing already downloaded data.
        // Only first-use preparation waits for settings that are not cached yet.
        if try await store.printCompany() == nil {
            await printPreparation?.value
        }
        return try await InvoiceLocalPrinting.generate(invoiceID: invoice.id, store: store, language: language, printedBy: printedBy)
    }

    func detail(for invoice: Invoice) -> InvoiceDetailViewModel {
        InvoiceDetailViewModel(invoice: invoice, client: client, store: store)
    }

    func pendingEdits(isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) -> PendingInvoiceEditsViewModel {
        PendingInvoiceEditsViewModel(client: client, store: store, isAuthorized: isAuthorized, canEdit: canEdit)
    }

    func drafts(canGeneratePool: @escaping () -> Bool = { false }, canViewItemCatalog: @escaping () -> Bool = { false }, canViewCustomers: @escaping () -> Bool, canReviewPolicies: @escaping () -> Bool,
                canViewContainers: @escaping () -> Bool,
                canViewAssignments: @escaping (InvoiceAssignmentPermission) -> Bool,
                canReviewPayments: @escaping () -> Bool, currentBranchID: @escaping () -> UInt16?,
                defaultPaymentRegion: String? = nil,
                financialPermission: @escaping (InvoiceFinancialPermission) -> Bool = { _ in false },
                isAuthorized: @escaping () -> Bool) -> InvoiceDraftListViewModel {
        InvoiceDraftListViewModel(canGeneratePool: canGeneratePool, store: store, client: client, canViewItemCatalog: canViewItemCatalog, canViewCustomers: canViewCustomers,
            canReviewPolicies: canReviewPolicies, canViewContainers: canViewContainers,
            canViewAssignments: canViewAssignments, canReviewPayments: canReviewPayments,
            currentBranchID: currentBranchID, defaultPaymentRegion: defaultPaymentRegion,
            financialPermission: financialPermission, isAuthorized: isAuthorized)
    }

    func load(query newQuery: InvoiceListQuery? = nil, online: Bool = true) async {
        let token = UUID()
        generation = token
        query = newQuery ?? query
        let requestedQuery = query
        page = 0
        isLoading = true
        issue = nil
        isShowingDownloaded = !online
        invoices = []
        hasMore = false
        defer { if generation == token { isLoading = false } }
        localEntries = []
        if requestedQuery.scope == .unsynced || !requestedQuery.requiresSearch {
            do {
                let entries = try await store.localInvoiceListEntries(includeRecentConfirmed: requestedQuery.scope == .all)
                try Task.checkCancellation()
                guard generation == token else { return }
                localEntries = entries.filter { $0.matches(requestedQuery) }
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                issue = "invoices.storageError"
            }
        }
        if requestedQuery.scope == .unsynced {
            isShowingDownloaded = false
            return
        }
        if online {
            await fetch(page: 1, query: requestedQuery, token: token)
        } else {
            await loadDownloaded(query: requestedQuery, token: token)
        }
    }

    private func loadDownloaded(query requestedQuery: InvoiceListQuery, token: UUID) async {
        do {
            let saved = try await store.matchingInvoices(requestedQuery)
            let balance = try await store.downloadedBalance()
            try Task.checkCancellation()
            guard generation == token else { return }
            invoices = saved
            isShowingDownloaded = true
            outstandingBalance = balance
            hasMore = saved.count == InvoiceListQuery.batchSize
        } catch is CancellationError { return }
        catch {
            guard generation == token else { return }
            issue = "invoices.storageError"
            return
        }
    }

    func loadMore(online: Bool = true) async {
        guard !isLoading, hasMore, issue == nil else { return }
        isLoading = true
        let token = generation
        defer { if generation == token { isLoading = false } }
        if isShowingDownloaded {
            do {
                let next = try await store.matchingInvoices(query, offset: invoices.count)
                try Task.checkCancellation()
                guard generation == token else { return }
                appendUnique(next)
                hasMore = next.count == InvoiceListQuery.batchSize
            } catch is CancellationError { return }
            catch { if generation == token { issue = "invoices.storageError" } }
        } else if online {
            await fetch(page: page + 1, query: query, token: token)
        }
    }

    func retry(online: Bool) async {
        if isShowingDownloaded || page == 0 { await load(online: online) }
        else {
            issue = nil
            await loadMore(online: online)
        }
    }

    /// Updates the directory from a complete repository page or falls back to local records.
    private func fetch(page requestedPage: Int, query requestedQuery: InvoiceListQuery, token: UUID) async {
        do {
            // The repository owns transport, persistence, and consistency checks.
            let result = try await repository.downloadPage(requestedPage, matching: requestedQuery) {
                generation == token
            }
            guard generation == token, !Task.isCancelled else {
                return
            }

            // Commit rows, totals, and pagination to the current search together.
            if requestedPage == 1 {
                invoices = []
            }
            appendUnique(result.invoices)
            page = requestedPage
            isShowingDownloaded = false
            hasMore = result.hasMore
            outstandingBalance = result.outstandingBalance
        } catch is CancellationError {
            // A newer search owns the screen state after cancellation.
        } catch {
            // Use local data for connection failures while surfacing server errors.
            guard generation == token, !Task.isCancelled else {
                return
            }
            if AuthenticationSession.permitsOfflineRestoration(error) {
                await loadDownloaded(query: requestedQuery, token: token)
            } else {
                issue = "invoices.refreshError"
            }
        }
    }

    /// Appends new invoice rows in source order and skips duplicate identities.
    private func appendUnique(_ values: [Invoice]) {
        // Retain the first displayed row when a later page repeats an invoice.
        var seen = Set(invoices.map(\.id))
        for invoice in values {
            if seen.insert(invoice.id).inserted {
                invoices.append(invoice)
            }
        }
    }
}
