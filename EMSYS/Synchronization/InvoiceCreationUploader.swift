import Foundation

@MainActor
struct InvoiceCreationUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: InvoiceStore
    var assignedOnly = false

    func synchronize() async throws {
        var needsAttention = false
        do { try await InvoicePoolSynchronizer(client: client, store: store).synchronizeActions() }
        catch APIClientError.sessionChanged { throw APIClientError.sessionChanged }
        catch { needsAttention = true }
        while true {
            let operations = try await store.pendingInvoiceCreations(assignedOnly: assignedOnly)
            guard !operations.isEmpty else { break }
            for operation in operations {
                try Task.checkCancellation()
                var stage: PendingInvoiceCreation.Failure.Stage = .invoice
                do {
                    if operation.invoiceRequest == nil, let journal = operation.journalRequest {
                        stage = .payment
                        let path = operation.plan.content.assignedPickup.map { "journals/sync/assigned/\($0.pickupID)" } ?? "journals/sync"
                        let receipt = try await client.post(path, encodedBody: journal, capturesServerFailure: true, as: InvoiceInitialPaymentReceipt.self)
                        try Task.checkCancellation()
                        try await store.saveInitialPaymentReceipt(creationID: operation.id, receipt: receipt)
                    }
                    guard let current = try await store.invoiceCreation(draftID: operation.draftID),
                          current.state == .pending, let request = current.invoiceRequest else { continue }
                    stage = .invoice
                    let path = current.plan.content.assignedPickup == nil ? "invoices/sync/create" : "invoices/sync/create-assigned"
                    let invoice = try await client.post(path, encodedBody: request, capturesServerFailure: true, as: Invoice.self)
                    try Task.checkCancellation()
                    try await store.completeInvoiceCreation(id: operation.id, invoice: invoice)
                } catch let error as APIServerFailure {
                    let state: PendingInvoiceCreation.State
                    switch error.status {
                    case 400, 409, 422: state = .needsReview
                    case 401, 403: state = .authorizationRequired
                    case 404, 405, 413: state = .serverUnavailable
                    default: throw APIClientError.httpStatus(error.status)
                    }
                    try await store.setInvoiceCreationState(id: operation.id, state: state,
                        failure: .init(stage: stage, status: error.status, code: error.code,
                                       message: error.message.map { String($0.prefix(300)) }))
                    needsAttention = true
                } catch InvoiceCreationPlan.PlanError.invalidReceipt, InvoiceStore.StoreError.invalidCreationReceipt {
                    // A decoded but inconsistent acknowledgement needs explicit
                    // review. Keep frozen bytes and any confirmed payment, and
                    // allow unrelated queued invoices to continue uploading.
                    try await store.setInvoiceCreationState(id: operation.id, state: .needsReview,
                        failure: .init(stage: stage, status: nil))
                    needsAttention = true
                }
            }
        }
        let remaining = try await store.activeInvoiceCreationCount(assignedOnly: assignedOnly)
        if needsAttention || remaining > 0 { throw UploadError.attentionRequired }
    }
}
