import Foundation

/// Uploads durable edits before refreshing cached pages/details. Missing list
/// entries are never treated as deletion confirmations.
@MainActor
struct InvoiceSynchronizer {
    let client: APIClient
    let store: InvoiceStore

    /// Uploads queued changes, refreshes the offline cache, and resumes attachments.
    func synchronize() async throws {
        // Blocked changes remain actionable while independent downloads continue.
        var needsAttention = false
        do {
            try await InvoiceMutationUploader(client: client, store: store).synchronize()
        } catch InvoiceMutationUploader.UploadError.attentionRequired {
            needsAttention = true
        }
        // Refresh the first page and all previously cached pages and invoice details.
        let pages = try await store.downloadedPages()
        let detailIDs = try await store.downloadedDetailIDs()
        for page in Set(pages + [1]).sorted() {
            try Task.checkCancellation()
            let version = try await store.downloadVersion()
            let invoices = try await client.get("invoices", queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "40"),
                URLQueryItem(name: "sort", value: "id:desc")
            ], as: [Invoice].self)
            try Task.checkCancellation()
            try await store.saveDownloaded(invoices, page: page, ifUnchangedSince: version)
        }
        for id in detailIDs {
            try Task.checkCancellation()
            try await InvoiceDetailDownloader(client: client, store: store).download(invoiceID: id)
        }
        // Downloaded list/detail records may have supplied the container that
        // locally captured documents were waiting for. Upload them in this run.
        do {
            try await InvoiceAttachmentUploader(client: client, store: store).synchronize()
        } catch InvoiceAttachmentUploader.UploadError.attentionRequired {
            needsAttention = true
        }
        if needsAttention {
            throw InvoiceMutationUploader.UploadError.attentionRequired
        }
    }
}
