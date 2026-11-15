import Foundation

/// Coordinates durable reservation actions with the server's invoice pool.
@MainActor
struct InvoicePoolRepository {
    let store: InvoiceStore
    let client: APIClient?

    /// Reads the device's local reservations and pending action count.
    func status() async throws -> (available: Int, reservations: [InvoiceReservation], threshold: Int, pendingCount: Int) {
        try await store.invoicePoolStatus()
    }

    /// Replays staged actions and reports whether the local pool was refreshed.
    func refresh(isAuthorized: () -> Bool) async throws -> Bool {
        // Local-only sessions can still read their existing reservations.
        guard let client, isAuthorized() else {
            return false
        }
        try await synchronize(using: client)
        return true
    }

    /// Saves the action before attempting to reconcile it with the server.
    func submit(_ kind: InvoicePoolAction.Kind, items: [InvoiceReservation], isAuthorized: () -> Bool) async throws {
        // Persist the device and request identity so a failed upload can be retried.
        let deviceID = try await store.invoicePoolDeviceID()
        let action = InvoicePoolAction(action: kind, deviceID: deviceID, items: items)
        try await store.stageInvoicePoolAction(action)

        // Keep the action queued when the session cannot send it.
        guard let client, isAuthorized() else {
            throw APIClientError.invalidResponse
        }
        try await synchronize(using: client)
    }

    /// Reconciles pending mutations before loading the authoritative pool.
    private func synchronize(using client: APIClient) async throws {
        let synchronizer = InvoicePoolSynchronizer(client: client, store: store)
        try await synchronizer.synchronizeActions()
        try await synchronizer.downloadCurrentPool()
    }
}
