import Foundation

nonisolated struct PickupSyncSnapshot: Codable, Sendable {
    let pickup: Pickup
    let revision: String
    var requestId: String? = nil
    var invoiceContexts: [PickupInvoiceContext]? = nil

    var isValid: Bool {
        pickup.id > 0 && revision.hasPrefix("v1:") && revision.count == 67
            && revision.dropFirst(3).allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

nonisolated struct PickupCompletion: Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending, needsReview, authorizationRequired, serverUnavailable, completed
        var title: String { "pickupSync." + rawValue }
    }
    struct Request: Codable, Sendable {
        let requestId: String
        let revision: String
    }
    let id: UUID
    let pickupID: UInt32
    let request: Data
    let state: State
}
