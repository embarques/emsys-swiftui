import Foundation

/// Coordinates the pickup directory's network download and local projections.
@MainActor
struct PickupRepository {
    let client: APIClient
    let store: PickupStore

    struct Page {
        let pickups: [Pickup]
        let hasMore: Bool
    }

    /// Refreshes one page and reads it back with pending local changes applied.
    func downloadPage(query: PickupListQuery, page: Int, isAuthorized: () -> Bool) async throws -> Page {
        let completed = query.status == .completed
        let queryItems = [
            URLQueryItem(name: "completed", value: completed ? "true" : "false"),
            URLQueryItem(name: "sort", value: "date:desc,id:desc")
        ]
        let request = query.request(page: page)
        let records: [Pickup]

        // Use the sync endpoint when available so offline invoice context keeps its revision.
        do {
            let snapshots = try await client.post("pickups/sync/search", body: request,
                queryItems: queryItems, as: [PickupSyncSnapshot].self)
            try verifyPage(count: snapshots.count, isAuthorized: isAuthorized)
            try await store.save(snapshots)
            records = snapshots.map(\.pickup)
        } catch APIClientError.httpStatus(let status) where status == 404 || status == 405 {
            // Older servers provide pickup records through the existing search endpoint.
            let legacy = try await client.post("pickups/search", body: request,
                queryItems: queryItems, as: [Pickup].self)
            try verifyPage(count: legacy.count, isAuthorized: isAuthorized)
            try await store.save(legacy)
            records = legacy
        }

        // Batch the local projection instead of opening one read transaction per row.
        try verifyPage(count: records.count, isAuthorized: isAuthorized)
        let ids = records.map(\.id)
        let saved = try await store.pickups(ids: ids)
        return Page(pickups: saved, hasMore: records.count == PickupListQuery.batchSize)
    }

    /// Rejects incomplete authorization and oversized responses before any local write.
    private func verifyPage(count: Int, isAuthorized: () -> Bool) throws {
        // A revoked session must never write records from its delayed response.
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }

        // The endpoint contract bounds each page to the requested batch size.
        guard count <= PickupListQuery.batchSize else {
            throw APIClientError.invalidResponse
        }
    }

    /// Reads the pickup and its saved completion from the device.
    func localDetail(id: UInt32) async throws -> (pickup: Pickup?, completion: PickupCompletion?, revision: String?) {
        try await store.detail(id: id)
    }

    /// Downloads the pickup and returns whether the server supplied a synchronization revision.
    func downloadDetail(id: UInt32, isAuthorized: () -> Bool) async throws -> Bool {
        // A revision is required before a completion can be queued.
        do {
            let snapshot = try await client.get("pickups/sync/\(id)", as: PickupSyncSnapshot.self)
            try Task.checkCancellation()
            guard isAuthorized(), snapshot.pickup.id == id else {
                throw APIClientError.sessionChanged
            }
            try await store.save(snapshot)
            return true
        } catch APIClientError.httpStatus(404) {
            // The older endpoint can refresh the visible pickup without granting write access.
            let pickup = try await client.get("pickups/\(id)", as: Pickup.self)
            guard isAuthorized(), pickup.id == id else {
                throw APIClientError.sessionChanged
            }
            try await store.save([pickup])
            return false
        }
    }

    /// Replaces a rejected local completion with the server's current pickup.
    func discardRejectedCompletion(id: UInt32, isAuthorized: () -> Bool) async throws {
        // Keep the rejected intent until the matching replacement can be saved atomically.
        let snapshot = try await client.get("pickups/sync/\(id)", as: PickupSyncSnapshot.self)
        guard isAuthorized(), snapshot.pickup.id == id else {
            throw APIClientError.sessionChanged
        }
        try await store.discardRejectedCompletion(id: id, snapshot: snapshot)
    }

    /// Runs the existing completion outbox for the current session.
    func synchronizeCompletions(isAuthorized: @escaping () -> Bool) async throws {
        let uploader = PickupCompletionUploader(client: client, store: store, isAuthorized: isAuthorized)
        try await uploader.synchronize()
    }
}
