import Foundation

nonisolated struct PendingInvoiceCreation: Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending, needsReview, authorizationRequired, serverUnavailable, completed
        var title: String { "invoiceCreation.status.\(rawValue)" }
    }
    struct Failure: Codable, Sendable {
        enum Stage: String, Codable, Sendable {
            case payment, invoice
            var title: String { "invoiceCreation.failure.\(rawValue)" }
        }
        let stage: Stage
        let status: Int?
    }

    let id: UUID
    let draftID: UUID
    let state: State
    let plan: InvoiceCreationPlan
    let journalRequest: Data?
    let invoiceRequest: Data?
    let invoiceID: String?
    var failure: Failure? = nil
}
