import Foundation
import Observation

@MainActor
@Observable
final class InvoicePoolPreferenceViewModel {
    var threshold = 10 {
        didSet {
            // A further edit invalidates the previous save confirmation.
            saved = false
        }
    }
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var saved = false
    private var storedThreshold = 10
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let repository: InvoicePoolPreferenceRepository
    @ObservationIgnored private let isAuthorized: () -> Bool

    /// Opens the threshold editor with the current user's preferences.
    init(store: InvoiceStore, client: APIClient, isAuthorized: @escaping () -> Bool) {
        self.store = store
        self.repository = InvoicePoolPreferenceRepository(store: store, client: client)
        self.isAuthorized = isAuthorized
    }

    /// Checks that there is an authorized change in the supported range.
    var canSave: Bool {
        isAuthorized() && !isLoading && threshold != storedThreshold
            && InvoicePoolPreference.isValidThreshold(threshold)
    }

    /// Shows the saved local value while refreshing it from the server.
    func load() async {
        guard isAuthorized(), !isLoading else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        issue = nil

        do {
            // Load the offline copy before requesting the current preference.
            let cached = try await store.invoicePoolThreshold()
            guard isAuthorized() else {
                return
            }
            threshold = cached
            storedThreshold = cached

            // Only the current session can display the downloaded value.
            let downloaded = try await repository.refresh(isAuthorized: isAuthorized)
            guard isAuthorized() else {
                return
            }
            threshold = downloaded
            storedThreshold = downloaded
        } catch {
            if isAuthorized() {
                issue = "settings.invoicePool.loadError"
            }
        }
    }

    /// Saves the requested value and marks it confirmed after the server acknowledges it.
    func save() async {
        guard canSave else {
            return
        }
        let requested = threshold
        isLoading = true
        saved = false
        issue = nil
        defer {
            isLoading = false
        }

        do {
            // Capture the submitted value so completion tracks the exact request.
            try await repository.save(requested, isAuthorized: isAuthorized)
            guard isAuthorized() else {
                return
            }
            storedThreshold = requested
            saved = true
        } catch {
            if isAuthorized() {
                issue = "settings.invoicePool.saveError"
            }
        }
    }
}
