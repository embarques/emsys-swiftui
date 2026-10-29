import Foundation

nonisolated enum PickupInvoicePrefill {
    enum PrefillError: Error { case invalidPickup, missingSender, chooseReceiver }

    static func receivers(in pickup: Pickup) -> [Pickup.Party] {
        var seen = Set<String>()
        return (pickup.receivers ?? []).filter {
            guard let id = $0.id, InvoiceWriteDocument.isObjectID(id) else { return false }
            return seen.insert(id).inserted
        }
    }

    static func content(from pickup: Pickup, receiverID: String? = nil) throws -> InvoiceDraft.Content {
        guard pickup.id > 0 else { throw PrefillError.invalidPickup }
        guard let sender = customer(pickup.sender, role: .sender) else { throw PrefillError.missingSender }
        let choices = receivers(in: pickup)
        let receiver: Pickup.Party?
        if let receiverID {
            guard let chosen = choices.first(where: { $0.id == receiverID }) else { throw PrefillError.chooseReceiver }
            receiver = chosen
        } else {
            guard choices.count <= 1 else { throw PrefillError.chooseReceiver }
            receiver = choices.first
        }
        var content = InvoiceDraft.Content()
        content.pickup = InvoicePickupReference(id: pickup.id)
        content.senderCustomer = sender
        content.senderName = sender.name
        content.receiverCustomer = customer(receiver, role: .receiver)
        content.receiverName = content.receiverCustomer?.name ?? ""
        // Pickup instructions are not priced invoice descriptions. Preserve the
        // wizard's catalog selection and review rather than inventing line items.
        return content
    }

    private static func customer(_ party: Pickup.Party?, role: InvoiceCustomer.Role) -> InvoiceCustomer? {
        guard let party, let id = party.id else { return nil }
        let customer = InvoiceCustomer(id: id, name: party.name ?? "", customerType: role.rawValue,
            active: nil, phones: party.phones, addresses: nil)
        return customer.isValid ? customer : nil
    }
}
