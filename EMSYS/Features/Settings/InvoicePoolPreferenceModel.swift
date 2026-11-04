import Foundation
import Observation

nonisolated struct InvoicePoolPreference: Codable, Sendable {
    let invoicePoolThreshold: Int
}

@MainActor
@Observable
final class InvoicePoolPreferenceModel {
    var threshold = 10 { didSet { saved = false } }
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var saved = false
    private var storedThreshold = 10
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(store: InvoiceStore, client: APIClient, isAuthorized: @escaping () -> Bool) {
        self.store = store
        self.client = client
        self.isAuthorized = isAuthorized
    }

    var canSave: Bool { isAuthorized() && !isLoading && threshold != storedThreshold && (0...10_000).contains(threshold) }

    func load() async {
        guard isAuthorized(), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        issue = nil
        do {
            let cached = try await store.invoicePoolThreshold()
            guard isAuthorized() else { return }
            threshold = cached
            storedThreshold = cached
            let preference = try await client.get("users/me/preferences", as: InvoicePoolPreference.self)
            guard isAuthorized(), (0...10_000).contains(preference.invoicePoolThreshold) else { throw APIClientError.invalidResponse }
            try await store.saveInvoicePoolThreshold(preference.invoicePoolThreshold)
            guard isAuthorized() else { return }
            threshold = preference.invoicePoolThreshold
            storedThreshold = threshold
        } catch { if isAuthorized() { issue = "settings.invoicePool.loadError" } }
    }

    func save() async {
        guard canSave else { return }
        let requested = threshold
        isLoading = true
        saved = false
        issue = nil
        defer { isLoading = false }
        do {
            let preference = try await client.patch("users/me/preferences", body: InvoicePoolPreference(invoicePoolThreshold: requested), as: InvoicePoolPreference.self)
            guard isAuthorized(), preference.invoicePoolThreshold == requested else { throw APIClientError.invalidResponse }
            try await store.saveInvoicePoolThreshold(requested)
            guard isAuthorized() else { return }
            storedThreshold = requested
            saved = true
        } catch { if isAuthorized() { issue = "settings.invoicePool.saveError" } }
    }
}
