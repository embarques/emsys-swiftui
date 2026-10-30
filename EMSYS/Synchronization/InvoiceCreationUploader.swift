import Foundation

@MainActor
struct InvoiceCreationUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore
    var assignedOnly = false

    func synchronize() async throws {
        var needsAttention = false
        while true {
            let operations = try await store.pendingInvoiceCreations(assignedOnly: assignedOnly)
            guard !operations.isEmpty else { break }
            for operation in operations {
                try Task.checkCancellation()
                do {
                    if operation.invoiceRequest == nil, let journal = operation.journalRequest {
                        let path = operation.plan.content.assignedPickup.map { "journals/sync/assigned/\($0.pickupID)" } ?? "journals/sync"
                        let receipt = try await client.post(path, encodedBody: journal, as: InvoiceInitialPaymentReceipt.self)
                        try Task.checkCancellation()
                        try await store.saveInitialPaymentReceipt(creationID: operation.id, receipt: receipt)
                    }
                    guard let current = try await store.invoiceCreation(draftID: operation.draftID),
                          current.state == .pending, let request = current.invoiceRequest else { continue }
                    let path = current.plan.content.assignedPickup == nil ? "invoices/sync/create" : "invoices/sync/create-assigned"
                    let invoice = try await client.post(path, encodedBody: request, as: Invoice.self)
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
                } catch InvoiceCreationPlan.PlanError.invalidReceipt, InvoiceStore.StoreError.invalidCreationReceipt {
                    // A decoded but inconsistent acknowledgement needs explicit
                    // review. Keep frozen bytes and any confirmed payment, and
                    // allow unrelated queued invoices to continue uploading.
                    try await store.setInvoiceCreationState(id: operation.id, state: .needsReview)
                    needsAttention = true
                }
            }
        }
        let remaining = try await store.activeInvoiceCreationCount(assignedOnly: assignedOnly)
        if needsAttention || remaining > 0 { throw UploadError.attentionRequired }
    }
}
