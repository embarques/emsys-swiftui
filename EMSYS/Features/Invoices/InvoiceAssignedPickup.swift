import Foundation

/// Local authorization context; API values stay in pickup and customer fields.
nonisolated struct InvoiceAssignedPickup: Codable, Equatable, Sendable {
    let pickupID: UInt32
    let senderID: String
    let receiverID: String?

    func matches(_ content: InvoiceDraft.Content) -> Bool {
        pickupID > 0 && content.pickup?.id == pickupID
            && content.senderCustomer?.id == senderID
            && content.senderWriteSnapshot?.id == senderID
            && content.senderName == content.senderWriteSnapshot?.name
            && content.receiverCustomer?.id == receiverID
            && content.receiverWriteSnapshot?.id == receiverID
            && (receiverID == nil ? content.receiverName.isEmpty : content.receiverName == content.receiverWriteSnapshot?.name)
    }
}
