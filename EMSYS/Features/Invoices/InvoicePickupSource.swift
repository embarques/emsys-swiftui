import Foundation

nonisolated enum InvoicePickupSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case route, warehouse, office
    var id: Self { self }
    var title: String { "pickupSource.\(rawValue)" }
}
