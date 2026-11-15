import Foundation

/// Upload each durable business-operation family without hiding blocked work.
@MainActor
struct InvoiceMutationUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore

    /// Uploads each durable change family in dependency order.
    func synchronize() async throws {
        // Report blocked work after giving other eligible operations a chance to upload.
        var needsAttention = false
        do {
            try await InvoiceCreationUploader(client: client, store: store).synchronize()
        } catch InvoiceCreationUploader.UploadError.attentionRequired {
            needsAttention = true
        }

        // Existing invoices can still accept edits when a separate draft needs attention.
        do {
            try await InvoiceEditUploader(client: client, store: store).synchronize()
        } catch InvoiceEditUploader.UploadError.attentionRequired {
            needsAttention = true
        }

        // File uploads run last so recently confirmed invoices can receive their attachments.
        do {
            try await InvoiceAttachmentUploader(client: client, store: store).synchronize()
        } catch InvoiceAttachmentUploader.UploadError.attentionRequired {
            needsAttention = true
        }
        if needsAttention {
            throw UploadError.attentionRequired
        }
    }
}
