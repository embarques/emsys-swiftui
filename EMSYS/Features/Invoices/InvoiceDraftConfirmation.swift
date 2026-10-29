import CryptoKit
import Foundation

/// Confirmation belongs to the reviewed content, never just a customer name.
nonisolated struct InvoiceDraftConfirmation: Codable, Equatable, Sendable {
    let contextHash: Data
    var policiesAgreed: Bool
    var skipSignature: Bool

    static func contextHash(for content: InvoiceDraft.Content) throws -> Data {
        var reviewed = content
        reviewed.confirmation = nil
        reviewed.senderSignature = nil
        reviewed.wizardStep = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(reviewed)))
    }

    func matches(_ content: InvoiceDraft.Content) -> Bool {
        (try? Self.contextHash(for: content)) == contextHash
    }

    var isValid: Bool { contextHash.count == 32 }
}
