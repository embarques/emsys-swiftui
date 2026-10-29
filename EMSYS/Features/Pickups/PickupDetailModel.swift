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
    private(set) var completion: PickupCompletion?
    private(set) var revision: String?
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

    var canComplete: Bool {
        isAuthorized() && canUpdate() && !pickup.isComplete && !isLoading && completion == nil && revision != nil && !isUnavailable
    }
    var canPrepareCompletion: Bool { isAuthorized() && canUpdate() && !pickup.isComplete && completion == nil }
    var canRetry: Bool { isAuthorized() && canUpdate() && completion != nil && completion?.state != .needsReview }

    func refresh(online: Bool) async {
        guard isAuthorized(), !isLoading else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            try await loadLocal()
            guard online else { return }
            try await download()
            isUnavailable = false
        } catch { await handleReadFailure(error) }
    }

    func complete(online: Bool) async {
        guard canComplete, let revision else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            _ = try await store.queueCompletion(id: pickup.id, revision: revision)
            try await loadLocal()
            if online {
                try await PickupCompletionUploader(client: client, store: store, isAuthorized: { self.isAuthorized() && self.canUpdate() }).synchronize()
                try await loadLocal()
            }
        } catch PickupStore.StoreError.changed {
            issue = "pickupSync.changedLocally"
        } catch {
            if isAuthorized() { issue = "pickupSync.retryHint"; try? await loadLocal() }
        }
    }

    func retryCompletion() async {
        guard canRetry, let completion, !isLoading else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            try await store.setCompletionState(id: completion.id, state: .pending)
            try await PickupCompletionUploader(client: client, store: store, isAuthorized: { self.isAuthorized() && self.canUpdate() }).synchronize()
            try await loadLocal()
        } catch {
            if isAuthorized() { issue = "pickupSync.retryHint"; try? await loadLocal() }
        }
    }

    /// A conflict is a server rejection, unlike an unknown connection outcome.
    /// Explicitly accept a newly downloaded server copy before another intent.
    func discardRejectedCompletion() async {
        guard completion?.state == .needsReview, isAuthorized(), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await client.get("pickups/sync/\(pickup.id)", as: PickupSyncSnapshot.self)
            guard isAuthorized(), snapshot.pickup.id == pickup.id else { throw APIClientError.sessionChanged }
            try await store.discardRejectedCompletion(id: pickup.id, snapshot: snapshot)
            try await loadLocal()
            issue = nil
        } catch { await handleReadFailure(error) }
    }

    private func loadLocal() async throws {
        let saved = try await store.pickup(id: pickup.id)
        let operation = try await store.completion(id: pickup.id)
        let revision = try await store.revision(id: pickup.id)
        guard isAuthorized(), !Task.isCancelled else { return }
        if let saved { pickup = saved }
        completion = operation
        self.revision = revision
        requiresRefresh = operation?.state == .needsReview
    }

    private func download() async throws {
        do {
            let snapshot = try await client.get("pickups/sync/\(pickup.id)", as: PickupSyncSnapshot.self)
            try Task.checkCancellation()
            guard isAuthorized(), snapshot.pickup.id == pickup.id else { throw APIClientError.sessionChanged }
            try await store.save(snapshot)
        } catch APIClientError.httpStatus(404) {
            // Read-only compatibility is safe. Never fall back to ordinary PUT.
            let current = try await client.get("pickups/\(pickup.id)", as: Pickup.self)
            guard isAuthorized(), current.id == pickup.id else { throw APIClientError.sessionChanged }
            try await store.save([current])
            issue = "pickupSync.downloadRequired"
        }
        try await loadLocal()
    }

    private func handleReadFailure(_ error: Error) async {
        guard isAuthorized(), !(error is CancellationError) else { return }
        if case APIClientError.httpStatus(let status) = error, status == 403 || status == 404 {
            try? await store.remove(id: pickup.id)
            issue = "pickups.noLongerAvailable"
            isUnavailable = true
        } else { issue = "pickups.refreshError" }
    }
}
