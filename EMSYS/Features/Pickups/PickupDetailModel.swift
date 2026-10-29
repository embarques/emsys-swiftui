import Foundation
import Observation

@MainActor
@Observable
final class PickupDetailModel {
    private(set) var pickup: Pickup
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var requiresRefresh = false
    private(set) var isUnavailable = false
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: PickupStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canUpdate: () -> Bool

    init(pickup: Pickup, client: APIClient, store: PickupStore,
         isAuthorized: @escaping () -> Bool, canUpdate: @escaping () -> Bool) {
        self.pickup = pickup
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
        self.canUpdate = canUpdate
    }

    var canComplete: Bool { isAuthorized() && canUpdate() && !pickup.isComplete && !isLoading && !requiresRefresh }

    func refresh(online: Bool) async {
        guard isAuthorized(), !isLoading else { return }
        guard online else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            try await download()
            requiresRefresh = false
            isUnavailable = false
        } catch { await handleReadFailure(error) }
    }

    func complete(online: Bool) async {
        guard canComplete else { return }
        guard online else { issue = "pickups.completionOnline"; return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            // Only patch the documented field. A read projection must never
            // replace customer snapshots, route assignments or server metadata.
            try await download()
            guard isAuthorized(), canUpdate(), !Task.isCancelled else { return }
            if pickup.isComplete { return }
            requiresRefresh = true
            let updated = try await client.put("pickups/\(pickup.id)",
                encodedBody: Data(#"{"completed":true}"#.utf8), as: Pickup.self)
            guard updated.id == pickup.id, updated.completed else { throw APIClientError.invalidResponse }
            guard isAuthorized() else { return }
            try await store.save([updated])
            try await download()
            guard pickup.completed else { throw APIClientError.invalidResponse }
            requiresRefresh = false
        } catch {
            guard isAuthorized() else { return }
            // Once PUT starts, its outcome can be unknown. Refresh explicitly;
            // do not automatically replay a mutation lacking a sync contract.
            if requiresRefresh { issue = "pickups.completionUnknown" }
            else { await handleReadFailure(error) }
        }
    }

    private func download() async throws {
        let current = try await client.get("pickups/\(pickup.id)", as: Pickup.self)
        try Task.checkCancellation()
        guard current.id == pickup.id else { throw APIClientError.invalidResponse }
        guard isAuthorized() else { throw APIClientError.sessionChanged }
        try await store.save([current])
        guard isAuthorized() else { throw APIClientError.sessionChanged }
        pickup = current
    }

    private func handleReadFailure(_ error: Error) async {
        guard isAuthorized(), !(error is CancellationError) else { return }
        if case APIClientError.httpStatus(let status) = error, status == 403 || status == 404 {
            try? await store.remove(id: pickup.id)
            issue = "pickups.noLongerAvailable"
            requiresRefresh = true
            isUnavailable = true
        } else { issue = "pickups.refreshError" }
    }
}
