import Foundation

@MainActor
struct InvoiceCreationUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore

    func synchronize() async throws {
        var needsAttention = false
        while true {
            let operations = try await store.pendingInvoiceCreations()
            guard !operations.isEmpty else { break }
            for operation in operations {
                try Task.checkCancellation()
                do {
                    if operation.invoiceRequest == nil, let journal = operation.journalRequest {
                        let receipt = try await client.post("journals/sync", encodedBody: journal, as: InvoiceInitialPaymentReceipt.self)
                        try Task.checkCancellation()
                        try await store.saveInitialPaymentReceipt(creationID: operation.id, receipt: receipt)
                    }
                    guard let current = try await store.invoiceCreation(draftID: operation.draftID),
                          current.state == .pending, let request = current.invoiceRequest else { continue }
                    let invoice = try await client.post("invoices/sync/create", encodedBody: request, as: Invoice.self)
                    try Task.checkCancellation()
                    try await store.completeInvoiceCreation(id: operation.id, invoice: invoice)
                } catch APIClientError.httpStatus(let status) where [400, 409, 422].contains(status) {
                    try await store.setInvoiceCreationState(id: operation.id, state: .needsReview)
                    needsAttention = true
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    try await store.setInvoiceCreationState(id: operation.id, state: .authorizationRequired)
                    needsAttention = true
                } catch APIClientError.httpStatus(let status) where [404, 405, 413].contains(status) {
                    // The new routes may not be deployed; ordinary creation or
                    // posting must never serve as an unsafe fallback.
                    try await store.setInvoiceCreationState(id: operation.id, state: .serverUnavailable)
                    needsAttention = true
                } catch InvoiceCreationPlan.PlanError.invalidReceipt {
                    try await store.setInvoiceCreationState(id: operation.id, state: .needsReview)
                    needsAttention = true
                }
            }
        }
        let remaining = try await store.activeInvoiceCreationCount()
        if needsAttention || remaining > 0 { throw UploadError.attentionRequired }
    }
}
