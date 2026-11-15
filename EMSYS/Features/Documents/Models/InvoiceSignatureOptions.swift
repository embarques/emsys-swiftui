import Foundation

nonisolated struct InvoiceSignatureOptions: Decodable, Sendable {
    struct Sender: Decodable, Sendable {
        let signerName: String
    }
    struct Receiver: Decodable, Identifiable, Sendable {
        let id: String
        let signerName: String
        let deliveryID: UInt32?
        let deliveryName: String?
        let signedAt: String?

        private enum CodingKeys: String, CodingKey {
            case id, signerName, deliveryName, signedAt
            case deliveryID = "deliveryId"
        }

        var signedDate: Date? {
            guard let signedAt else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: signedAt) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: signedAt)
        }
    }

    let invoiceID: String
    let invoiceNumber: String
    let senderSignature: Sender?
    let receiverSignatures: [Receiver]

    private enum CodingKeys: String, CodingKey {
        case invoiceNumber, senderSignature, receiverSignatures
        case invoiceID = "invoiceId"
    }
}
