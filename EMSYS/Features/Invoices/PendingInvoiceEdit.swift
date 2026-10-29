import Foundation

nonisolated struct PendingInvoiceEdit: Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case needsReview
        case authorizationRequired
        case serverUnavailable
        case completed
        case discarded
        case superseded
    }

    let id: UUID
    let invoiceID: String
    let invoiceNumber: String?
    let expectedRevision: String
    let requestBody: Data
    let changes: [InvoiceWriteDocument.ItemNameChange]
    let createdAt: Date
    let state: State
    let attempts: Int
}
