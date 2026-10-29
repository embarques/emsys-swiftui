import Foundation

@MainActor
struct InvoiceDetailDownloader {
    let client: APIClient
    let store: InvoiceStore

    func download(invoiceID: String) async throws {
        guard InvoiceWriteDocument.isObjectID(invoiceID) else { throw APIClientError.invalidPath }
        let version = try await store.downloadVersion()
        do {
            let snapshot = try await client.get("invoices/sync/\(invoiceID)", as: InvoiceEditSnapshot.self)
            try snapshot.validate(invoiceID: invoiceID)
            try Task.checkCancellation()
            try await store.saveEditSnapshot(snapshot, ifUnchangedSince: version)
        } catch APIClientError.httpStatus(let status) where [404, 503].contains(status) {
            // Read compatibility during rollout. This never enables an update
            // without a server revision or falls back to unconditional writes.
            let invoice = try await client.get("invoices/\(invoiceID)", as: Invoice.self)
            guard invoice.id == invoiceID else { throw APIClientError.invalidResponse }
            try Task.checkCancellation()
            try await store.saveDownloaded([invoice], ifUnchangedSince: version)
        }
    }
}
