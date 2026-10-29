import Foundation

/// An unfinished local form. It has no server invoice number or financial status.
nonisolated struct InvoiceDraft: Identifiable, Sendable {
    struct Content: Codable, Equatable, Sendable {
        var pickup: InvoicePickupReference?
        var attachments: [InvoiceAttachment]?
        var senderSignature: InvoiceSenderSignature?
        var confirmation: InvoiceDraftConfirmation?
        var wizardStep: InvoiceCreationStep?
        var date = InvoiceDate(date: .now)
        var senderName = ""
        var receiverName = ""
        var items = [Item()]
        var senderWriteSnapshot: InvoiceCustomerWriteSnapshot?
        var receiverWriteSnapshot: InvoiceCustomerWriteSnapshot?
        var senderCustomer: InvoiceCustomer?
        var receiverCustomer: InvoiceCustomer?
        var senderAddressID: String?
        var receiverAddressID: String?
        var policies: [InvoicePolicy]?
        var container: InvoiceContainer?
        var pickupSource: InvoicePickupSource?
        var pickupRoute: InvoicePickupRoute?
        var pickupEmployee: InvoicePickupEmployee?
        var payment: InvoiceDraftPayment?
        var paymentRegion: String?
        var paymentReview: InvoicePaymentReview?

        init() { }

        private enum CodingKeys: String, CodingKey {
            case pickup, attachments, senderSignature, confirmation, wizardStep
            case senderWriteSnapshot, receiverWriteSnapshot, senderCustomer, receiverCustomer
            case senderAddressID, receiverAddressID, policies, container, pickupSource
            case pickupRoute, pickupEmployee, payment, paymentRegion, paymentReview
            case date, senderName, receiverName, items
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            pickup = try fields.decodeIfPresent(InvoicePickupReference.self, forKey: .pickup)
            attachments = try fields.decodeIfPresent([InvoiceAttachment].self, forKey: .attachments)
            senderSignature = try fields.decodeIfPresent(InvoiceSenderSignature.self, forKey: .senderSignature)
            confirmation = try fields.decodeIfPresent(InvoiceDraftConfirmation.self, forKey: .confirmation)
            wizardStep = try fields.decodeIfPresent(InvoiceCreationStep.self, forKey: .wizardStep)
            senderWriteSnapshot = try fields.decodeIfPresent(InvoiceCustomerWriteSnapshot.self, forKey: .senderWriteSnapshot)
            receiverWriteSnapshot = try fields.decodeIfPresent(InvoiceCustomerWriteSnapshot.self, forKey: .receiverWriteSnapshot)
            senderCustomer = try fields.decodeIfPresent(InvoiceCustomer.self, forKey: .senderCustomer)
            receiverCustomer = try fields.decodeIfPresent(InvoiceCustomer.self, forKey: .receiverCustomer)
            senderAddressID = try fields.decodeIfPresent(String.self, forKey: .senderAddressID)
            receiverAddressID = try fields.decodeIfPresent(String.self, forKey: .receiverAddressID)
            policies = try fields.decodeIfPresent([InvoicePolicy].self, forKey: .policies)
            container = try fields.decodeIfPresent(InvoiceContainer.self, forKey: .container)
            pickupSource = try fields.decodeIfPresent(InvoicePickupSource.self, forKey: .pickupSource)
            pickupRoute = try fields.decodeIfPresent(InvoicePickupRoute.self, forKey: .pickupRoute)
            pickupEmployee = try fields.decodeIfPresent(InvoicePickupEmployee.self, forKey: .pickupEmployee)
            payment = try fields.decodeIfPresent(InvoiceDraftPayment.self, forKey: .payment)
            paymentRegion = try fields.decodeIfPresent(String.self, forKey: .paymentRegion)
            paymentReview = try fields.decodeIfPresent(InvoicePaymentReview.self, forKey: .paymentReview)
            date = try fields.decode(InvoiceDate.self, forKey: .date)
            senderName = try fields.decode(String.self, forKey: .senderName)
            receiverName = try fields.decode(String.self, forKey: .receiverName)
            items = try fields.decode([Item].self, forKey: .items)
            // Upgrade old drafts/plans in memory without changing frozen
            // journal or invoice request bytes already queued for retry.
            if senderSignature == nil,
               let legacy = try fields.decodeIfPresent(LegacyConfirmationSignature.self, forKey: .confirmation),
               let png = legacy.signaturePNG {
                senderSignature = InvoiceSenderSignature(signerName: senderName,
                    data: png.base64EncodedString(), contentType: "image/png")
            }
        }

        private struct LegacyConfirmationSignature: Decodable {
            let signaturePNG: Data?
        }
    }

    struct Item: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        var name: String
        var quantity: String
        var unitPrice: String
        var labelCount: String
        var total: String

        init(id: UUID = UUID(), name: String = "", quantity: String = "1",
             unitPrice: String = "", labelCount: String = "", total: String = "") {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.unitPrice = unitPrice
            self.labelCount = labelCount
            self.total = total
        }
    }

    let id: UUID
    let revision: Int64
    let savedAt: Date
    let content: Content
}

nonisolated struct InvoiceDraftSummary: Identifiable, Sendable {
    let id: UUID
    let revision: Int64
    let savedAt: Date
    let senderName: String
    let receiverName: String
    let itemCount: Int
    var creationState: PendingInvoiceCreation.State? = nil
    var pendingAttachmentCount: Int = 0
}
