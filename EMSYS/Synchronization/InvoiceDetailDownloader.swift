import Foundation

@MainActor
struct InvoiceDetailDownloader {
    let client: APIClient
    let store: InvoiceStore

    /// Refreshes invoice details, using the compatible read-only endpoint if needed.
    func download(invoiceID: String) async throws {
        guard InvoiceWriteDocument.isObjectID(invoiceID) else {
            throw APIClientError.invalidPath
        }
        let version = try await store.downloadVersion()
        do {
            _ = try await downloadSnapshot(invoiceID: invoiceID, version: version, isAuthorized: { true })
        } catch APIClientError.httpStatus(let status) where [404, 503].contains(status) {
            // Read compatibility during rollout. This never enables an update
            // without a server revision or falls back to unconditional writes.
            let invoice = try await client.get("invoices/\(invoiceID)", as: Invoice.self)
            guard invoice.id == invoiceID else {
                throw APIClientError.invalidResponse
            }
            try Task.checkCancellation()
            try await store.saveDownloaded([invoice], ifUnchangedSince: version)
        }
    }

    /// Downloads a versioned snapshot for conflict review without using the compatibility route.
    func downloadSnapshot(invoiceID: String, isAuthorized: () -> Bool) async throws -> InvoiceEditSnapshot {
        let version = try await store.downloadVersion()
        return try await downloadSnapshot(invoiceID: invoiceID, version: version, isAuthorized: isAuthorized)
    }

    /// Persists a verified snapshot only while its caller and local revision remain current.
    private func downloadSnapshot(invoiceID: String, version: Int64,
                                  isAuthorized: () -> Bool) async throws -> InvoiceEditSnapshot {
        let snapshot = try await client.get("invoices/sync/\(invoiceID)", as: InvoiceEditSnapshot.self)
        try snapshot.validate(invoiceID: invoiceID)

        // Keep in-flight results from overwriting changes made during this request.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
        try await store.saveEditSnapshot(snapshot, ifUnchangedSince: version)
        return snapshot
    }
}
