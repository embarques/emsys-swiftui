import Foundation

nonisolated struct InvoicePickupEmployee: Codable, Equatable, Identifiable, Sendable {
    let id: UInt16
    let name: String?
    let title: String?
    let department: String?
    let active: Bool?
    let branch: InvoicePickupBranch?

    var isValid: Bool { id > 0 }
    var isEligible: Bool { active == true && branch?.isDeliveryBranch != true }
    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return String(id) }
        return name
    }

    func matches(_ source: InvoicePickupSource, branchTypes: [UInt16: String]) -> Bool {
        guard isEligible else { return false }
        let branchType = branch.flatMap { branchTypes[$0.id] }?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let warehouseRole = [department, title].compactMap { $0 }
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "warehouse" }
        switch source {
        case .route: return false
        case .warehouse: return branchType == "warehouse" || warehouseRole
        case .office: return branchType == "office" || (!warehouseRole && branchType != "warehouse")
        }
    }
}
