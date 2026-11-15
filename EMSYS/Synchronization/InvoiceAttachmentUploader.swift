import Foundation

@MainActor
struct InvoiceAttachmentUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore

    /// Uploads queued attachments and leaves recoverable failures in the outbox.
    func synchronize() async throws {
        // Process pending attachments until the store reports that the queue is empty.
        while true {
            let attachments = try await store.invoiceAttachments(pendingOnly: true)
            guard !attachments.isEmpty else {
                break
            }
            // Upload only attachments linked to a valid server invoice.
            for pending in attachments {
                try Task.checkCancellation()
                guard let invoiceID = pending.invoiceID, InvoiceWriteDocument.isObjectID(invoiceID) else {
                    throw InvoiceStore.StoreError.invalidDraft
                }
                do {
                    // Reuse the persisted upload ID and boundary for any retry.
                    let body = try await store.attachmentBody(id: pending.id)
                    let receipt = try await client.upload("invoices/\(invoiceID)/documents", encodedBody: body,
                        boundary: InvoiceAttachmentUpload.boundary(for: pending.attachment), as: InvoiceDocumentReceipt.self)
                    try Task.checkCancellation()
                    try await store.completeAttachment(pending, receipt: receipt)
                } catch APIClientError.httpStatus(let status) where [400, 409, 415, 422].contains(status) {
                    // Keep rejected attachments available for review.
                    try await store.setAttachmentState(id: pending.id, state: .needsReview)
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    // Wait for authorization before another upload.
                    try await store.setAttachmentState(id: pending.id, state: .authorizationRequired)
                } catch APIClientError.httpStatus(let status) where [404, 405, 413].contains(status) {
                    // Preserve pending data when the endpoint cannot accept the upload.
                    try await store.setAttachmentState(id: pending.id, state: .serverUnavailable)
                } catch InvoiceStore.StoreError.invalidDraft {
                    // Invalid stored data needs review before it can be retried.
                    try await store.setAttachmentState(id: pending.id, state: .needsReview)
                }
            }
        }
        // Attachments still waiting for a container are handled by assignment refresh.
        let remainingCount = try await store.activeAttachmentCount(excludingAwaitingContainer: true)
        if remainingCount > 0 {
            throw UploadError.attentionRequired
        }
    }
}

/// Encodes the stable multipart request expected by the invoice documents endpoint.
nonisolated enum InvoiceAttachmentUpload {
    /// Derives the boundary from the persisted ID so retries use the same bytes.
    static func boundary(for attachment: InvoiceAttachment) -> String {
        "EMSYS-\(attachment.id.uuidString)"
    }

    /// Validates the attachment and encodes its ID and file in HTTP field order.
    static func encode(_ attachment: InvoiceAttachment, bytes: Data) throws -> Data {
        // Reject corrupted bytes or unsafe filename metadata before writing headers.
        guard attachment.validates(bytes) else {
            throw InvoiceAttachment.AttachmentError.invalidFile
        }

        // Keep field order and CRLF delimiters identical for queued uploads.
        let boundary = boundary(for: attachment)
        let headers = [
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"uploadId\"",
            "",
            attachment.id.uuidString,
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(attachment.name)\"",
            "Content-Type: \(attachment.mimeType)",
            "",
            ""
        ]
        var body = Data(headers.joined(separator: "\r\n").utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
