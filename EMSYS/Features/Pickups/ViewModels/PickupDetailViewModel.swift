import Foundation
import Observation

@MainActor
@Observable
final class PickupDetailViewModel {
    private(set) var pickup: Pickup
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var requiresRefresh = false
    private(set) var isUnavailable = false
    private(set) var completion: PickupCompletion?
    private(set) var revision: String?
    @ObservationIgnored private let repository: PickupRepository
    @ObservationIgnored private let store: PickupStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canUpdate: () -> Bool

    /// Opens the detail for a pickup and captures the session permissions for its actions.
    init(pickup: Pickup, client: APIClient, store: PickupStore,
         isAuthorized: @escaping () -> Bool, canUpdate: @escaping () -> Bool) {
        self.pickup = pickup
        self.repository = PickupRepository(client: client, store: store)
        self.store = store
        self.isAuthorized = isAuthorized
        self.canUpdate = canUpdate
    }

    /// Checks that an authorized user can complete the downloaded pickup revision.
    var canComplete: Bool {
        isAuthorized() && canUpdate() && !pickup.isComplete && !isLoading && completion == nil && revision != nil && !isUnavailable
    }
    /// Checks whether the user can start preparing this pickup for completion.
    var canPrepareCompletion: Bool { isAuthorized() && canUpdate() && !pickup.isComplete && completion == nil }
    /// Checks whether the saved intent can be retried without resolving a conflict.
    var canRetry: Bool { isAuthorized() && canUpdate() && completion != nil && completion?.state != .needsReview }

    /// Restores the local pickup and refreshes it from the server when online.
    func refresh(online: Bool) async {
        guard isAuthorized(), !isLoading else {
            return
        }
        isLoading = true
        issue = nil
        defer {
            isLoading = false
        }
        do {
            try await loadLocal()
            guard online else {
                return
            }
            try await download()
            isUnavailable = false
        } catch {
            await handleReadFailure(error)
        }
    }

    /// Queues the completion locally and attempts to upload it when online.
    func complete(online: Bool) async {
        guard canComplete, let revision else {
            return
        }
        isLoading = true
        issue = nil
        defer {
            isLoading = false
        }
        do {
            // Save the operation before attempting network synchronization.
            _ = try await store.queueCompletion(id: pickup.id, revision: revision)
            try await loadLocal()
            if online {
                try await repository.synchronizeCompletions {
                    self.isAuthorized() && self.canUpdate()
                }
                try await loadLocal()
            }
        } catch PickupStore.StoreError.changed {
            issue = "pickupSync.changedLocally"
        } catch {
            // The original intent remains available for another attempt.
            if isAuthorized() {
                issue = "pickupSync.retryHint"
                try? await loadLocal()
            }
        }
    }

    /// Retries the existing completion request with its original identity.
    func retryCompletion() async {
        guard canRetry, let completion, !isLoading else {
            return
        }
        isLoading = true
        issue = nil
        defer {
            isLoading = false
        }
        do {
            // Make the same saved request eligible for upload again.
            try await store.setCompletionState(id: completion.id, state: .pending)
            try await repository.synchronizeCompletions {
                self.isAuthorized() && self.canUpdate()
            }
            try await loadLocal()
        } catch {
            // The original intent remains available for another attempt.
            if isAuthorized() {
                issue = "pickupSync.retryHint"
                try? await loadLocal()
            }
        }
    }

    /// A conflict is a server rejection, unlike an unknown connection outcome.
    /// Explicitly accept a newly downloaded server copy before another intent.
    func discardRejectedCompletion() async {
        guard completion?.state == .needsReview, isAuthorized(), !isLoading else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        do {
            // Keep the rejected completion visible until its replacement is saved.
            try await repository.discardRejectedCompletion(id: pickup.id, isAuthorized: isAuthorized)
            try await loadLocal()
            issue = nil
        } catch {
            await handleReadFailure(error)
        }
    }

    /// Applies the saved pickup, completion, and revision to the screen.
    private func loadLocal() async throws {
        let detail = try await repository.localDetail(id: pickup.id)

        // A delayed read can finish after the user signs out or closes the screen.
        guard isAuthorized(), !Task.isCancelled else {
            return
        }
        if let saved = detail.pickup {
            pickup = saved
        }
        completion = detail.completion
        revision = detail.revision
        requiresRefresh = detail.completion?.state == .needsReview
    }

    /// Refreshes the pickup and flags servers that omit its write revision.
    private func download() async throws {
        let providesRevision = try await repository.downloadDetail(id: pickup.id, isAuthorized: isAuthorized)
        if !providesRevision {
            issue = "pickupSync.downloadRequired"
        }
        try await loadLocal()
    }

    /// Reports network errors and removes pickups that are no longer accessible.
    private func handleReadFailure(_ error: Error) async {
        guard isAuthorized(), !(error is CancellationError) else {
            return
        }
        if case APIClientError.httpStatus(let status) = error, status == 403 || status == 404 {
            // Hide the inaccessible pickup while preserving queued work.
            try? await store.remove(id: pickup.id)
            issue = "pickups.noLongerAvailable"
            isUnavailable = true
        } else {
            issue = "pickups.refreshError"
        }
    }
}
