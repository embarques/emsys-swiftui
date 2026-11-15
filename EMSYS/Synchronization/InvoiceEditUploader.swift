import Foundation

@MainActor
struct InvoiceEditUploader {
    enum UploadError: Error { case attentionRequired }

    let client: APIClient
    let store: InvoiceStore

    /// Posts recorded edits and moves conflicts to their recoverable outbox state.
    func synchronize() async throws {
        // Reconsider edits blocked by server access before reading the sendable queue.
        try await store.retryBlockedEdits()
        while true {
            let edits = try await store.pendingEdits()
            if edits.isEmpty {
                break
            }
            // Record the attempt before sending the saved request body.
            for edit in edits {
                try Task.checkCancellation()
                guard try await store.recordAttempt(editID: edit.id) else {
                    continue
                }
                do {
                    let snapshot = try await client.put("invoices/sync/\(edit.invoiceID)", encodedBody: edit.requestBody, as: InvoiceEditSnapshot.self)
                    try Task.checkCancellation()
                    // Validate the server identity before applying its edit projection.
                    try snapshot.validate(invoiceID: edit.invoiceID)
                    try await store.completeEdit(editID: edit.id, snapshot: snapshot)
                } catch APIClientError.httpStatus(let status) where [400, 409, 422].contains(status) {
                    // Conflicts need review before another write.
                    try await store.requireReview(editID: edit.id, state: .needsReview)
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    // Retain the edit until the user can upload it again.
                    try await store.requireReview(editID: edit.id, state: .authorizationRequired)
                } catch APIClientError.httpStatus(404) {
                    // The API route may not be deployed yet. Never fall back to
                    // the old unconditional PUT or infer that local work is gone.
                    try await store.requireReview(editID: edit.id, state: .serverUnavailable)
                }
            }
        }
        // An empty sendable queue can still contain unresolved edits.
        let activeCount = try await store.activeEditCount()
        if activeCount > 0 {
            throw UploadError.attentionRequired
        }
    }
}
