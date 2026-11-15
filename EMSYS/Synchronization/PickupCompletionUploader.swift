import Foundation

@MainActor
struct PickupCompletionUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: PickupStore
    let isAuthorized: () -> Bool

    /// Sends offline completions while their original session remains authorized.
    func synchronize() async throws {
        // Check both pending uploads and records waiting for operator attention.
        while isAuthorized() {
            let operations = try await store.pendingCompletions()
            if operations.isEmpty {
                let activeCount = try await store.activeCompletionCount()
                if activeCount > 0 {
                    throw UploadError.attentionRequired
                }
                return
            }
            // Each retry sends the same durable completion request.
            for operation in operations {
                try Task.checkCancellation()
                guard isAuthorized() else {
                    throw APIClientError.sessionChanged
                }
                do {
                    let snapshot = try await client.post("pickups/sync/\(operation.pickupID)/complete",
                        encodedBody: operation.request, as: PickupSyncSnapshot.self)
                    // Never apply an acknowledgement to a replacement session.
                    guard isAuthorized() else {
                        throw APIClientError.sessionChanged
                    }
                    try await store.acknowledgeCompletion(operation, snapshot: snapshot)
                } catch APIClientError.httpStatus(let status) where [400, 409, 422].contains(status) {
                    // Preserve conflicts for user review.
                    try await store.setCompletionState(id: operation.id, state: .needsReview)
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    // Retain the operation until permissions are restored.
                    try await store.setCompletionState(id: operation.id, state: .authorizationRequired)
                } catch APIClientError.httpStatus(let status) where [404, 405].contains(status) {
                    // Keep the operation durable if the sync route is unavailable.
                    try await store.setCompletionState(id: operation.id, state: .serverUnavailable)
                }
            }
        }
        throw APIClientError.sessionChanged
    }
}
