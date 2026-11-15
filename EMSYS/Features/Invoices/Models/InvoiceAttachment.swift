import CryptoKit
import Foundation

/// Metadata stored with the invoice draft and used to verify its attachment bytes.
nonisolated struct InvoiceAttachment: Codable, Equatable, Identifiable, Sendable {
    static let maximumSize = 25 * 1024 * 1024

    enum AttachmentError: Error {
        case invalidFile
        case unsupportedType
        case tooLarge
    }

    let id: UUID
    let name: String
    let mimeType: String
    let size: Int
    let digest: Data

    /// Checks the persisted metadata before it is accepted by the store or encoder.
    var isValid: Bool {
        // Reject missing metadata and sizes that cannot be accepted by the API.
        guard !name.isEmpty, name.count <= 200, size > 0, size <= Self.maximumSize, digest.count == 32 else {
            return false
        }

        // These characters cannot appear in the upload filename header.
        let disallowedScalars = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: #"/\""#))
        guard name.unicodeScalars.allSatisfy({ !disallowedScalars.contains($0) }) else {
            return false
        }

        // Accept only the MIME types supported by attachment import.
        let supportedTypes: Set<String> = [
            "application/pdf", "image/jpeg", "image/png", "image/gif", "image/webp",
            "image/bmp", "image/tiff", "image/heic", "image/heif", "image/avif"
        ]
        return supportedTypes.contains(mimeType)
    }

    /// Verifies that the stored bytes still match the original size and digest.
    func validates(_ bytes: Data) -> Bool {
        // Avoid hashing bytes when their metadata or length already fails validation.
        guard isValid, bytes.count == size else {
            return false
        }

        let storedDigest = Data(SHA256.hash(data: bytes))
        return storedDigest == digest
    }
}

nonisolated struct PendingInvoiceAttachment: Identifiable, Sendable {
    enum State: String, Sendable { case waiting, awaitingContainer, pending, needsReview, authorizationRequired, serverUnavailable, completed }
    let attachment: InvoiceAttachment
    let invoiceID: String?
    let state: State
    /// Returns the attachment identity used by the outbox.
    var id: UUID { attachment.id }
}

nonisolated struct InvoiceDocumentReceipt: Decodable, Sendable {
    let id: String
    let invoiceId: String
    let originalName: String
    let mimeType: String
    let size: Int
}
