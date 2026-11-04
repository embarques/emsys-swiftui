import Foundation
@testable import EMSYS

@MainActor
func seedInvoicePoolFixture(_ store: InvoiceStore, prefix: String = "INV-TEST-", start: Int = 1) async throws {
    let deviceID = try await store.invoicePoolDeviceID()
    let items = (0..<100).map { index in
        InvoiceReservation(id: String(format: "%024x", index + 3), number: "\(prefix)\(index + start)",
            allocation: .init(employeeId: 12, token: UUID().uuidString.lowercased(), deviceId: deviceID.uuidString.lowercased()))
    }
    try await store.reconcileInvoiceReservations(items, lowThreshold: 10)
}
