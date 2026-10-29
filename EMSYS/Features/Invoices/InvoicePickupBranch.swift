import Foundation

nonisolated struct InvoicePickupBranch: Codable, Equatable, Identifiable, Sendable {
    let id: UInt16
    let name: String?
    let code: String?
    let type: String?

    var isDeliveryBranch: Bool {
        ["RD", "DR", "DO"].contains(code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "")
    }
}
