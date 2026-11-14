import Foundation

nonisolated struct PendingInvoiceCreation: Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending, needsReview, replacementReady, authorizationRequired, serverUnavailable, completed
        var title: String { "invoiceCreation.status.\(rawValue)" }
    }
    struct Failure: Codable, Sendable {
        enum Stage: String, Codable, Sendable {
            case payment, invoice
            var title: String { "invoiceCreation.failure.\(rawValue)" }
        }
        let stage: Stage
        let status: Int?
        var code: String? = nil
        var message: String? = nil

        var isDuplicateInvoiceNumber: Bool { status == 409 && message == "Invoice already exists" }

        var requiresCloseout: Bool { stage == .payment && status == 409 && code == "CLOSEOUT_REQUIRED" }
    }

    let id: UUID
    let draftID: UUID
    let state: State
    let plan: InvoiceCreationPlan
    let journalRequest: Data?
    let invoiceRequest: Data?
    let invoiceID: String?
    var failure: Failure? = nil
    var paymentReceipt: InvoiceInitialPaymentReceipt? = nil

    var canReplaceInvoiceNumber: Bool {
        state == .needsReview && failure?.isDuplicateInvoiceNumber == true
            && invoiceID == nil && paymentReceipt == nil
            && (!plan.requiresJournal || (failure?.stage == .payment && invoiceRequest == nil))
    }
}
