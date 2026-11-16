import Foundation

/// Refreshes invoice draft reference data and keeps complete copies available offline.
@MainActor
struct InvoiceDraftRepository {
    static let containerPageSize = 40

    let store: InvoiceStore
    let client: APIClient

    /// Downloads bank accounts and updates SQLite after the full list is validated.
    func refreshBankAccounts(isAuthorized: () -> Bool) async throws -> [InvoiceBankAccount] {
        let accounts = try await downloadPages(
            path: "chart-accounts",
            query: [
                .init(name: "field", value: "type"),
                .init(name: "operator", value: "eq"),
                .init(name: "value", value: "BANK"),
                .init(name: "sort", value: "id:asc")
            ],
            identity: \InvoiceBankAccount.id,
            isValid: \InvoiceBankAccount.isValid,
            isAuthorized: isAuthorized
        )

        // Only a complete result replaces the previous offline copy.
        try await store.saveInvoiceBankAccounts(accounts)
        return accounts
    }

    /// Downloads the item catalog in the server's display order and saves it locally.
    func refreshItemCatalog(isAuthorized: () -> Bool) async throws -> [InvoiceCatalogItem] {
        let items = try await downloadPages(
            path: "invoice-descriptions",
            query: [.init(name: "sort", value: "createdAt:desc,id:desc")],
            identity: \InvoiceCatalogItem.id,
            isValid: \InvoiceCatalogItem.isValid,
            isAuthorized: isAuthorized
        )

        // Keep the previous catalog when any page is missing or invalid.
        try await store.saveItemCatalog(items)
        return items
    }

    /// Reads the current closeout for the branch responsible for payment.
    func currentCloseout(branchID: UInt16) async throws -> InvoiceIncomeStatement? {
        try await IncomeRepository.closeoutContext(client: client, branchID: branchID).current
    }

    /// Opens the server's current business day for payment and invoice recovery.
    func openCloseout(currency: String, rate: Double) async throws -> InvoiceIncomeStatement {
        try await IncomeRepository.openCloseout(client: client, currency: currency, rate: rate)
    }

    /// Downloads a customer's write snapshot and keeps it for offline draft preparation.
    func refreshCustomer(
        id: String,
        isCurrent: () -> Bool,
        accepts: (InvoiceCustomerWriteSnapshot) -> Bool
    ) async throws -> InvoiceCustomerWriteSnapshot {
        let snapshot = try await client.get("customers/\(id)", as: InvoiceCustomerWriteSnapshot.self)

        // Never cache a stale selection or a response for the wrong customer.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        guard accepts(snapshot) else {
            throw APIClientError.invalidResponse
        }
        try await store.saveCustomerWriteSnapshot(snapshot)
        return snapshot
    }

    /// Downloads eligible pickup routes and refreshes the local route directory.
    func refreshPickupRoutes(isAuthorized: () -> Bool) async throws -> [InvoicePickupRoute] {
        let routes = try await InvoiceAssignmentDownloader(client: client).routes(isAuthorized: isAuthorized)

        // A revoked grant cannot publish or persist the delayed response.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
        try await store.savePickupRoutes(routes)
        return routes
    }

    /// Downloads eligible employees and refreshes the local assignment directory.
    func refreshPickupEmployees(isAuthorized: () -> Bool) async throws -> [InvoicePickupEmployee] {
        let employees = try await InvoiceAssignmentDownloader(client: client).employees(isAuthorized: isAuthorized)

        // Recheck access before replacing the offline choices.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
        try await store.savePickupEmployees(employees)
        return employees
    }

    /// Refreshes the branch catalog used by payment and employee assignment.
    func refreshPaymentLocations(isAuthorized: () -> Bool) async throws -> [InvoicePickupBranch] {
        let branches = try await InvoiceAssignmentDownloader(client: client).branches(isAuthorized: isAuthorized)

        // Authorization can change while the page is being read.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
        try await store.savePickupBranches(branches)
        return branches
    }

    /// Refreshes invoice policies so they can be reviewed on a later offline session.
    func refreshPolicies(isAuthorized: () -> Bool) async throws -> [InvoicePolicy] {
        let policies = try await InvoicePolicyDownloader(client: client).download(isAuthorized: isAuthorized)

        // Keep the previous local policy set when the active user loses access.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
        try await store.savePolicies(policies)
        return policies
    }

    /// Refreshes the open income statement for the given branch and business day.
    func refreshPaymentReview(branchID: UInt16, day: InvoiceDate,
                              isCurrent: () -> Bool) async throws -> InvoicePaymentReview {
        let query = InvoiceIncomeStatementQuery(branchID: branchID, day: day)
        let statements = try await client.post("income-statements/search", body: query,
            as: [InvoiceIncomeStatement]?.self) ?? []

        // Reject responses for a session or branch that changed during loading.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }

        // The endpoint must return at most one statement for this branch and day.
        guard statements.count <= 1,
              statements.allSatisfy({ $0.matches(branchID: branchID, day: day) }) else {
            throw APIClientError.invalidResponse
        }

        // Save even an empty result so offline review represents the last download.
        let review = InvoicePaymentReview(branchID: branchID, day: day,
            statement: statements.first, downloadedAt: .now)
        try await store.savePaymentReview(review)
        return review
    }

    /// Searches customers by party role and keeps the validated results for offline search.
    func searchCustomers(term: String, role: InvoiceCustomer.Role,
                         isCurrent: () -> Bool) async throws -> [InvoiceCustomer] {
        let query = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "customerType", value: String(role.rawValue)),
            URLQueryItem(name: "limit", value: "20")
        ]
        let matches = try await client.get("customers/autocomplete",
            queryItems: query, as: [InvoiceCustomer.SearchResult].self)

        // A superseded query must not replace cached results.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        let downloaded = matches.map(\.customer)
        guard downloaded.allSatisfy({ $0.customerType == role.rawValue }) else {
            throw InvoiceStore.StoreError.invalidPageContents
        }
        try await store.saveCustomers(downloaded)
        return downloaded
    }

    /// Downloads one container page and rejects overlap with the previous pages.
    func searchContainers(term: String, page: Int, previousIDs: Set<UInt32>,
                          isCurrent: () -> Bool) async throws -> [InvoiceContainer] {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(Self.containerPageSize)),
            URLQueryItem(name: "sort", value: "id:desc")
        ]
        // An empty search uses the complete directory without a name filter.
        if !term.isEmpty {
            query.append(contentsOf: [
                URLQueryItem(name: "field", value: "name"),
                URLQueryItem(name: "operator", value: "contains"),
                URLQueryItem(name: "value", value: term)
            ])
        }
        let downloaded = try await client.get("containers", queryItems: query,
            as: [InvoiceContainer]?.self) ?? []

        // Refuse stale pages and overlapping rows before saving them.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        guard downloaded.allSatisfy({ !previousIDs.contains($0.id) }) else {
            throw APIClientError.invalidResponse
        }
        try await store.saveContainers(downloaded)
        return downloaded
    }

    /// Reads a bounded list of unique, validated reference records.
    private func downloadPages<Record: Decodable, ID: Hashable>(
        path: String,
        query: [URLQueryItem],
        identity: KeyPath<Record, ID>,
        isValid: KeyPath<Record, Bool>,
        isAuthorized: () -> Bool
    ) async throws -> [Record] {
        let pageSize = 40
        let maximumRecordCount = 1_000
        let maximumPageCount = 26
        var records: [Record] = []
        var identities: Set<ID> = []

        // Request each page once and stop when the server returns a short page.
        for page in 1...maximumPageCount {
            try Task.checkCancellation()
            guard isAuthorized() else {
                throw CancellationError()
            }
            let pageQuery = query + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(pageSize))
            ]
            let response = try await client.get(path, queryItems: pageQuery, as: [Record]?.self)
            let batch = response ?? []

            // A session change or cancellation makes the received page unusable.
            try Task.checkCancellation()
            guard isAuthorized() else {
                throw CancellationError()
            }

            // Reject oversized pages and repeated identities before updating the cache.
            guard batch.count <= pageSize, records.count + batch.count <= maximumRecordCount else {
                throw APIClientError.invalidResponse
            }
            for record in batch {
                let id = record[keyPath: identity]
                guard record[keyPath: isValid], identities.insert(id).inserted else {
                    throw APIClientError.invalidResponse
                }
                records.append(record)
            }
            if batch.count < pageSize {
                return records
            }
        }

        throw APIClientError.invalidResponse
    }
}
