/// The authority under which a pickup invoice screen was opened. A narrower
/// grant cannot keep an existing unrestricted screen authorized.
nonisolated enum PickupInvoiceAccess: Sendable {
    case company
    case assignedPickup

    init?(canCreateInvoices: Bool, canCreateAssignedInvoices: Bool) {
        if canCreateInvoices { self = .company }
        else if canCreateAssignedInvoices { self = .assignedPickup }
        else { return nil }
    }

    var assignedOnly: Bool { self == .assignedPickup }

    func permits(_ required: PickupInvoiceAccess) -> Bool {
        self == .company || self == required
    }
}
