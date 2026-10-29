import Foundation

/// Only the destination reference needed by a journal; no banking credentials.
nonisolated struct InvoiceBankAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String?
    let displayName: String?
    let type: String

    var isValid: Bool { id > 0 && type == "BANK" }
    var title: String { displayName ?? name ?? String(id) }
}
