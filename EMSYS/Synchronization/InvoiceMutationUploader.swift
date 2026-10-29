import Foundation

/// Upload each durable business-operation family without hiding blocked work.
@MainActor
struct InvoiceMutationUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore

    func synchronize() async throws {
        var needsAttention = false
        do { try await InvoiceCreationUploader(client: client, store: store).synchronize() }
        catch InvoiceCreationUploader.UploadError.attentionRequired { needsAttention = true }
        do { try await InvoiceEditUploader(client: client, store: store).synchronize() }
        catch InvoiceEditUploader.UploadError.attentionRequired { needsAttention = true }
        do { try await InvoiceAttachmentUploader(client: client, store: store).synchronize() }
        catch InvoiceAttachmentUploader.UploadError.attentionRequired { needsAttention = true }
        if needsAttention { throw UploadError.attentionRequired }
    }
}
