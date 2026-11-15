import Foundation
import Observation

@MainActor
@Observable
final class InvoiceCustomerSearchViewModel: Identifiable {
    let id = UUID()
    let role: InvoiceCustomer.Role
    var query = ""
    private(set) var customers: [InvoiceCustomer] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var issue: String?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let repository: InvoiceDraftRepository
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    /// Opens the customer picker with the current session and offline store.
    init(role: InvoiceCustomer.Role, client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.role = role
        self.repository = InvoiceDraftRepository(store: store, client: client)
        self.store = store
        self.isAuthorized = isAuthorized
    }

    /// Checks whether this session can keep the picker open.
    var isAvailable: Bool { isAuthorized() }

    /// Opens the cached customer results and refreshes them when connected.
    func search(online: Bool) async {
        // A new query supersedes any response still in flight.
        let request = UUID()
        requestID = request
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        customers = []
        issue = nil
        isShowingDownloaded = true
        guard isAuthorized() else {
            isLoading = false
            return
        }
        isLoading = true
        defer {
            // Only the current request can clear its loading state.
            if requestID == request {
                isLoading = false
            }
        }
        do {
            let saved = try await store.customers(matching: term, role: role)
            guard isCurrent(request) else {
                return
            }
            customers = saved
            guard online, !term.isEmpty else {
                return
            }
            // Only a current, authorized response may be saved or presented.
            let downloaded = try await repository.searchCustomers(term: term, role: role) {
                self.isCurrent(request)
            }
            guard isCurrent(request) else {
                return
            }
            customers = downloaded
            isShowingDownloaded = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(request) else {
                return
            }
            if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                customers = []
                issue = "auth.unavailable"
            } else {
                issue = "customers.searchError"
            }
        }
    }

    /// Checks if the request still belongs to the active search and session.
    private func isCurrent(_ request: UUID) -> Bool {
        requestID == request && isAuthorized() && !Task.isCancelled
    }
}
