import Foundation
import Observation

@MainActor
@Observable
final class InvoiceListModel {
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

    init(client: APIClient, store: InvoiceStore) {
        self.client = client
        self.store = store
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
            catch { printPreparation = nil; InvoiceLocalPrinting.logPreparationFailure(error) }
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

    func detail(for invoice: Invoice) -> InvoiceDetailModel {
        InvoiceDetailModel(invoice: invoice, client: client, store: store)
    }

    func pendingEdits(isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) -> PendingInvoiceEditsModel {
        PendingInvoiceEditsModel(client: client, store: store, isAuthorized: isAuthorized, canEdit: canEdit)
    }

    func drafts(canViewItemCatalog: @escaping () -> Bool = { false }, canViewCustomers: @escaping () -> Bool, canReviewPolicies: @escaping () -> Bool,
                canViewContainers: @escaping () -> Bool,
                canViewAssignments: @escaping (InvoiceAssignmentPermission) -> Bool,
                canReviewPayments: @escaping () -> Bool, currentBranchID: @escaping () -> UInt16?,
                financialPermission: @escaping (InvoiceFinancialPermission) -> Bool = { _ in false },
                isAuthorized: @escaping () -> Bool) -> InvoiceDraftListModel {
        InvoiceDraftListModel(store: store, client: client, canViewItemCatalog: canViewItemCatalog, canViewCustomers: canViewCustomers,
            canReviewPolicies: canReviewPolicies, canViewContainers: canViewContainers,
            canViewAssignments: canViewAssignments, canReviewPayments: canReviewPayments,
            currentBranchID: currentBranchID, financialPermission: financialPermission, isAuthorized: isAuthorized)
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

    private func fetch(page requestedPage: Int, query requestedQuery: InvoiceListQuery, token: UUID) async {
        do {
            let version = try await store.downloadVersion()
            let downloaded: [Invoice]
            if requestedQuery.requiresSearch {
                downloaded = try await client.post("invoices/search", body: requestedQuery.request(page: requestedPage),
                    queryItems: pagination(requestedPage), as: [Invoice].self)
            } else {
                downloaded = try await client.get("invoices", queryItems: pagination(requestedPage) + [
                    URLQueryItem(name: "sort", value: "date:desc,id:desc")
                ], as: [Invoice].self)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            guard downloaded.count <= InvoiceListQuery.batchSize else { throw InvoiceStore.StoreError.invalidPageContents }
            try await store.saveDownloaded(downloaded, ifUnchangedSince: version, asList: true)
            let effective = try await store.cachedInvoices(ids: downloaded.map(\.id))
            try Task.checkCancellation()
            guard generation == token else { return }
            guard try await store.downloadVersion() == version else {
                throw InvoiceStore.StoreError.editSnapshotChanged
            }
            if requestedPage == 1 { invoices = [] }
            appendUnique(effective)
            page = requestedPage
            isShowingDownloaded = false
            hasMore = downloaded.count == InvoiceListQuery.batchSize
            outstandingBalance = try await store.downloadedBalance()
        } catch is CancellationError { return }
        catch {
            guard generation == token, !Task.isCancelled else { return }
            if AuthenticationSession.permitsOfflineRestoration(error) {
                // A disconnected path or failed connection may precede the
                // network monitor update. HTTP/auth/server errors stay errors.
                await loadDownloaded(query: requestedQuery, token: token)
            } else {
                issue = "invoices.refreshError"
            }
        }
    }

    private func appendUnique(_ values: [Invoice]) {
        var seen = Set(invoices.map(\.id))
        invoices.append(contentsOf: values.filter { seen.insert($0.id).inserted })
    }

    private func pagination(_ page: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)),
         URLQueryItem(name: "limit", value: String(InvoiceListQuery.batchSize))]
    }
}
