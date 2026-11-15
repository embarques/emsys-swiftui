import Foundation

nonisolated struct InvoicePoolPreference: Codable, Sendable {
    let invoicePoolThreshold: Int

    /// Accepts the server-supported range for the local low-number warning.
    static func isValidThreshold(_ threshold: Int) -> Bool {
        (0...10_000).contains(threshold)
    }
}

@MainActor
struct InvoicePoolPreferenceRepository {
    let store: InvoiceStore
    let client: APIClient

    /// Refreshes the saved threshold after checking authorization and the server's range.
    func refresh(isAuthorized: () -> Bool) async throws -> Int {
        let preference = try await client.get("users/me/preferences", as: InvoicePoolPreference.self)
        let threshold = preference.invoicePoolThreshold

        // Keep the cached threshold if the server returned an invalid value.
        guard isAuthorized(), InvoicePoolPreference.isValidThreshold(threshold) else {
            throw APIClientError.invalidResponse
        }
        try await store.saveInvoicePoolThreshold(threshold)
        return threshold
    }

    /// Confirms the exact saved value before recording it for offline warnings.
    func save(_ threshold: Int, isAuthorized: () -> Bool) async throws {
        let requested = InvoicePoolPreference(invoicePoolThreshold: threshold)
        let preference = try await client.patch("users/me/preferences", body: requested,
            as: InvoicePoolPreference.self)

        // The response must acknowledge the value submitted by this session.
        guard isAuthorized(), preference.invoicePoolThreshold == threshold else {
            throw APIClientError.invalidResponse
        }
        try await store.saveInvoicePoolThreshold(threshold)
    }
}
