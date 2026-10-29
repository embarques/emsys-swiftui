import Foundation
import Observation

@MainActor
@Observable
final class InvoiceCustomerSearchModel: Identifiable {
    let id = UUID()
    let role: InvoiceCustomer.Role
    var query = ""
    private(set) var customers: [InvoiceCustomer] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var issue: String?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(role: InvoiceCustomer.Role, client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.role = role
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
    }

    var isAvailable: Bool { isAuthorized() }

    func search(online: Bool) async {
        let request = UUID()
        requestID = request
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        customers = []
        issue = nil
        isShowingDownloaded = true
        guard isAuthorized() else { isLoading = false; return }
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let saved = try await store.customers(matching: term, role: role)
            guard isCurrent(request) else { return }
            customers = saved
            guard online, !term.isEmpty else { return }
            let matches = try await client.get("customers/autocomplete", queryItems: [
                URLQueryItem(name: "q", value: term),
                URLQueryItem(name: "customerType", value: String(role.rawValue)),
                URLQueryItem(name: "limit", value: "20")
            ], as: [InvoiceCustomer.SearchResult].self)
            guard isCurrent(request) else { return }
            let downloaded = matches.map(\.customer)
            guard downloaded.allSatisfy({ $0.customerType == role.rawValue }) else { throw InvoiceStore.StoreError.invalidPageContents }
            try await store.saveCustomers(downloaded)
            guard isCurrent(request) else { return }
            customers = downloaded
            isShowingDownloaded = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(request) else { return }
            if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                customers = []
                issue = "auth.unavailable"
            } else {
                issue = "customers.searchError"
            }
        }
    }

    private func isCurrent(_ request: UUID) -> Bool {
        requestID == request && isAuthorized() && !Task.isCancelled
    }
}
