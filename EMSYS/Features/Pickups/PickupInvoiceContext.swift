import Foundation

/// API-shaped customer details scoped to one pickup and selected recipient.
nonisolated struct PickupInvoiceContext: Codable, Sendable {
    let pickupId: UInt32
    let revision: String
    let sender: InvoiceCustomerWriteSnapshot
    let receiver: InvoiceCustomerWriteSnapshot?

    func matches(_ pickup: Pickup, receiverID: String?) -> Bool {
        guard pickupId == pickup.id, sender.isValid, sender.customerType == 1,
              sender.id == pickup.sender?.id, revision.hasPrefix("v1:"), revision.count == 67 else { return false }
        let choices = PickupInvoicePrefill.receivers(in: pickup)
        let expected = receiverID ?? (choices.count == 1 ? choices.first?.id : nil)
        guard choices.count <= 1 || receiverID != nil else { return false }
        if let expected {
            return choices.contains { $0.id == expected } && receiver?.id == expected
                && receiver?.customerType == 2 && receiver?.isValid == true
        }
        return receiver == nil && choices.isEmpty
    }

    func content(from pickup: Pickup, receiverID: String?) throws -> InvoiceDraft.Content {
        guard matches(pickup, receiverID: receiverID) else { throw APIClientError.invalidResponse }
        var content = try PickupInvoicePrefill.content(from: pickup, receiverID: receiverID)
        content.senderCustomer = sender.publicCustomer(active: nil)
        content.senderName = sender.name
        content.senderWriteSnapshot = sender
        content.senderAddressID = sender.addresses?.first { InvoiceWriteDocument.isObjectID($0.id ?? "") }?.id
        if let receiver {
            content.receiverCustomer = receiver.publicCustomer(active: nil)
            content.receiverName = receiver.name
            content.receiverWriteSnapshot = receiver
            content.receiverAddressID = receiver.addresses?.first { InvoiceWriteDocument.isObjectID($0.id ?? "") }?.id
        }
        return content
    }
}
