import Foundation

@MainActor
struct InvoiceAttachmentUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore

    func synchronize() async throws {
        while true {
            let attachments = try await store.invoiceAttachments(pendingOnly: true)
            guard !attachments.isEmpty else { break }
            for pending in attachments {
                try Task.checkCancellation()
                guard let invoiceID = pending.invoiceID, InvoiceWriteDocument.isObjectID(invoiceID) else {
                    throw InvoiceStore.StoreError.invalidDraft
                }
                do {
                    let body = try await store.attachmentBody(id: pending.id)
                    let receipt = try await client.upload("invoices/\(invoiceID)/documents", encodedBody: body,
                        boundary: pending.attachment.boundary, as: InvoiceDocumentReceipt.self)
                    try Task.checkCancellation()
                    try await store.completeAttachment(pending, receipt: receipt)
                } catch APIClientError.httpStatus(let status) where [400, 409, 415, 422].contains(status) {
                    try await store.setAttachmentState(id: pending.id, state: .needsReview)
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    try await store.setAttachmentState(id: pending.id, state: .authorizationRequired)
                } catch APIClientError.httpStatus(let status) where [404, 405, 413].contains(status) {
                    try await store.setAttachmentState(id: pending.id, state: .serverUnavailable)
                } catch InvoiceStore.StoreError.invalidDraft {
                    try await store.setAttachmentState(id: pending.id, state: .needsReview)
                }
            }
        }
        if try await store.activeAttachmentCount(excludingAwaitingContainer: true) > 0 { throw UploadError.attentionRequired }
    }
}
