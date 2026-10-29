import Foundation

/// The same lightweight association accepted by invoice creation and sync.
nonisolated struct InvoicePickupReference: Codable, Equatable, Sendable {
    let id: UInt32
}
