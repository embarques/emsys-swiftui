import Foundation

/// Coordinates directory downloads with the SQLite invoice projections they update.
@MainActor
struct InvoiceDirectoryRepository {
    let client: APIClient
    let store: InvoiceStore

    struct Page {
        let invoices: [Invoice]
        let hasMore: Bool
        let outstandingBalance: Decimal
    }

    /// Downloads a page and returns the corresponding persisted invoice rows.
    func downloadPage(_ page: Int, matching query: InvoiceListQuery, isCurrent: () -> Bool) async throws -> Page {
        // Track local edits so the downloaded page cannot overwrite a newer projection.
        let version = try await store.downloadVersion()
        let pageSize = InvoiceListQuery.batchSize
        let pagination = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(pageSize))
        ]

        // Preserve the separate endpoints for ordinary lists and filtered searches.
        let downloaded: [Invoice]
        if query.requiresSearch {
            downloaded = try await client.post("invoices/search", body: query.request(page: page),
                queryItems: pagination, as: [Invoice].self)
        } else {
            let sorting = URLQueryItem(name: "sort", value: "date:desc,id:desc")
            downloaded = try await client.get("invoices", queryItems: pagination + [sorting], as: [Invoice].self)
        }

        // A superseded request cannot publish or save a stale server page.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        guard downloaded.count <= pageSize else {
            throw InvoiceStore.StoreError.invalidPageContents
        }

        // Read back local projections so outbox edits stay visible.
        try await store.saveDownloaded(downloaded, ifUnchangedSince: version, asList: true)
        let invoices = try await store.cachedInvoices(ids: downloaded.map(\.id))
        let balance = try await store.downloadedBalance()
        let currentVersion = try await store.downloadVersion()

        // If local edits arrived while reading, let the normal reload path recover.
        try Task.checkCancellation()
        guard isCurrent() else {
            throw CancellationError()
        }
        guard currentVersion == version else {
            throw InvoiceStore.StoreError.editSnapshotChanged
        }

        return Page(invoices: invoices, hasMore: downloaded.count == pageSize, outstandingBalance: balance)
    }
}
