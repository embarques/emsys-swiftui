import Foundation

nonisolated struct InvoicePickupRoute: Codable, Equatable, Identifiable, Sendable {
    struct Crew: Codable, Equatable, Sendable {
        let id: String
        let name: String?
    }
    let id: String
    let name: String?
    let date: String?
    let dayOfWeek: [String]?
    let branch: InvoicePickupBranch?
    let route: Crew?
    let routeType: String?
    let type: String?

    var isValid: Bool {
        InvoiceWriteDocument.isObjectID(id)
            && route.map { InvoiceWriteDocument.isObjectID($0.id) } == true
    }

    var isPickup: Bool { (routeType ?? type) == "pickup" && branch?.isDeliveryBranch != true }
    var displayName: String {
        [name, route?.name].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? id
    }
}
