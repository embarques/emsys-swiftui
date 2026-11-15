import Foundation

nonisolated enum PickupInvoicePrefill {
    enum PrefillError: Error { case invalidPickup, missingSender, chooseReceiver }

    /// Returns distinct valid receiver choices from the pickup in their saved order.
    static func receivers(in pickup: Pickup) -> [Pickup.Party] {
        // Preserve the first occurrence of each valid receiver identifier.
        var seen = Set<String>()
        var choices: [Pickup.Party] = []
        for receiver in pickup.receivers ?? [] {
            guard let id = receiver.id, InvoiceWriteDocument.isObjectID(id), seen.insert(id).inserted else {
                continue
            }
            choices.append(receiver)
        }
        return choices
    }

    /// Starts an invoice draft using the sender and selected receiver from a pickup.
    static func content(from pickup: Pickup, receiverID: String? = nil) throws -> InvoiceDraft.Content {
        guard pickup.id > 0 else {
            throw PrefillError.invalidPickup
        }
        guard let sender = customer(pickup.sender, role: .sender) else {
            throw PrefillError.missingSender
        }
        // An ambiguous pickup requires an explicit receiver before editing can begin.
        let choices = receivers(in: pickup)
        let receiver: Pickup.Party?
        if let receiverID {
            guard let chosen = choices.first(where: { $0.id == receiverID }) else {
                throw PrefillError.chooseReceiver
            }
            receiver = chosen
        } else {
            guard choices.count <= 1 else {
                throw PrefillError.chooseReceiver
            }
            receiver = choices.first
        }
        // Populate only party fields. Item selection still belongs to the operator.
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

    /// Converts a saved party into the corresponding valid invoice customer reference.
    private static func customer(_ party: Pickup.Party?, role: InvoiceCustomer.Role) -> InvoiceCustomer? {
        guard let party, let id = party.id else {
            return nil
        }
        let customer = InvoiceCustomer(id: id, name: party.name ?? "", customerType: role.rawValue,
            active: nil, phones: party.phones, addresses: nil)
        return customer.isValid ? customer : nil
    }
}
