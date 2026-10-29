import Foundation

@MainActor
struct PickupCompletionUploader {
    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: PickupStore
    let isAuthorized: () -> Bool

    func synchronize() async throws {
        while isAuthorized() {
            let operations = try await store.pendingCompletions()
            if operations.isEmpty {
                if try await store.activeCompletionCount() > 0 { throw UploadError.attentionRequired }
                return
            }
            for operation in operations {
                try Task.checkCancellation()
                guard isAuthorized() else { throw APIClientError.sessionChanged }
                do {
                    let snapshot = try await client.post("pickups/sync/\(operation.pickupID)/complete",
                        encodedBody: operation.request, as: PickupSyncSnapshot.self)
                    guard isAuthorized() else { throw APIClientError.sessionChanged }
                    try await store.acknowledgeCompletion(operation, snapshot: snapshot)
                } catch APIClientError.httpStatus(let status) where [400, 409, 422].contains(status) {
                    try await store.setCompletionState(id: operation.id, state: .needsReview)
                } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
                    try await store.setCompletionState(id: operation.id, state: .authorizationRequired)
                } catch APIClientError.httpStatus(let status) where [404, 405].contains(status) {
                    try await store.setCompletionState(id: operation.id, state: .serverUnavailable)
                }
            }
        }
        throw APIClientError.sessionChanged
    }
}
