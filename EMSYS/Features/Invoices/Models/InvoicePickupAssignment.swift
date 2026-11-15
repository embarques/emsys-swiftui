import Foundation

/// Local authorization context retained with an invoice derived from an assigned pickup.
nonisolated struct InvoiceAssignedPickup: Codable, Equatable, Sendable {
    let pickupID: UInt32
    let senderID: String
    let receiverID: String?

    /// Checks that the draft still uses the pickup and parties originally authorized.
    func matches(_ content: InvoiceDraft.Content) -> Bool {
        // Match the pickup and both snapshots for the sender.
        guard pickupID > 0, content.pickup?.id == pickupID,
              content.senderCustomer?.id == senderID, content.senderWriteSnapshot?.id == senderID,
              content.senderName == content.senderWriteSnapshot?.name else {
            return false
        }

        // An assigned receiver must match both its selected customer and its saved details.
        guard content.receiverCustomer?.id == receiverID, content.receiverWriteSnapshot?.id == receiverID else {
            return false
        }
        if receiverID == nil {
            return content.receiverName.isEmpty
        }
        return content.receiverName == content.receiverWriteSnapshot?.name
    }
}

/// The pickup identity accepted by invoice creation and synchronization.
nonisolated struct InvoicePickupReference: Codable, Equatable, Sendable {
    let id: UInt32
}

/// Describes where the invoice pickup originated.
nonisolated enum InvoicePickupSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case route
    case warehouse
    case office

    /// Identifies the source in selection controls.
    var id: Self { self }

    /// Resolves the source name in the selected app language.
    var title: String { "pickupSource.\(rawValue)" }
}

nonisolated struct InvoicePickupBranch: Codable, Equatable, Identifiable, Sendable {
    let id: UInt16
    let name: String?
    let code: String?
    let type: String?

    var isDeliveryBranch: Bool {
        ["RD", "DR", "DO"].contains(code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "")
    }
}

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
