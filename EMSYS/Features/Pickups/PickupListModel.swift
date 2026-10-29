import Foundation
import Observation

@MainActor
@Observable
final class PickupListModel {
    private(set) var pickups: [Pickup] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = false
    private(set) var issue: String?
    private(set) var hasMore = false
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var query = PickupListQuery()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: PickupStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(client: APIClient, store: PickupStore, isAuthorized: @escaping () -> Bool) {
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
    }

    func load(query: PickupListQuery, online: Bool) async {
        let token = UUID()
        generation = token
        self.query = query
        page = 0
        pickups = []
        hasMore = false
        issue = nil
        guard isAuthorized() else { return }
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            // Local records render before the network request; a failed refresh
            // leaves them available without pretending the server was reached.
            let cached = try await store.pickups(matching: query)
            guard generation == token, isAuthorized(), !Task.isCancelled else { return }
            pickups = cached
            isShowingDownloaded = true
            if online { try await fetch(page: 1, token: token) }
        } catch is CancellationError { }
        catch {
            await handleFailure(error, token: token)
        }
    }

    func loadMore() async {
        guard isAuthorized(), !isLoading, hasMore else { return }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do { try await fetch(page: page + 1, token: token) }
        catch is CancellationError { }
        catch { await handleFailure(error, token: token) }
    }

    func detail(_ pickup: Pickup, canUpdate: @escaping () -> Bool) -> PickupDetailModel {
        PickupDetailModel(pickup: pickup, client: client, store: store, isAuthorized: isAuthorized, canUpdate: canUpdate)
    }

    private func handleFailure(_ error: Error, token: UUID) async {
        guard generation == token, isAuthorized(), !Task.isCancelled else { return }
        if case APIClientError.httpStatus(let status) = error, status == 401 || status == 403 {
            pickups = []
            hasMore = false
            try? await store.removeAll()
        }
        guard generation == token, isAuthorized(), !Task.isCancelled else { return }
        if !AuthenticationSession.permitsOfflineRestoration(error) { issue = "pickups.refreshError" }
    }

    private func fetch(page: Int, token: UUID) async throws {
        let queryItems = [URLQueryItem(name: "completed", value: query.status == .completed ? "true" : "false"),
                          URLQueryItem(name: "sort", value: "date:desc,id:desc")]
        let records: [Pickup]
        do {
            let snapshots = try await client.post("pickups/sync/search", body: query.request(page: page),
                queryItems: queryItems, as: [PickupSyncSnapshot].self)
            guard snapshots.count <= PickupListQuery.batchSize else { throw APIClientError.invalidResponse }
            try Task.checkCancellation()
            guard generation == token, isAuthorized() else { return }
            try await store.save(snapshots)
            records = snapshots.map(\.pickup)
        } catch APIClientError.httpStatus(let status) where status == 404 || status == 405 {
            let legacy = try await client.post("pickups/search", body: query.request(page: page), queryItems: queryItems, as: [Pickup].self)
            guard legacy.count <= PickupListQuery.batchSize else { throw APIClientError.invalidResponse }
            try Task.checkCancellation()
            guard generation == token, isAuthorized() else { return }
            try await store.save(legacy)
            records = legacy
        }
        guard generation == token, isAuthorized(), !Task.isCancelled else { return }
        // Publish the persisted values rather than a separate transient source.
        var saved: [Pickup] = []
        for record in records {
            if let value = try await store.pickup(id: record.id) { saved.append(value) }
        }
        guard generation == token, isAuthorized(), !Task.isCancelled else { return }
        if page == 1 {
            pickups = try await store.pickups(matching: query).filter { $0.pendingCompletion == true }
            guard generation == token, isAuthorized() else { return }
        }
        var ids = Set(pickups.map(\.id))
        pickups.append(contentsOf: saved.filter { query.matches($0) && ids.insert($0.id).inserted })
        self.page = page
        hasMore = records.count == PickupListQuery.batchSize
        isShowingDownloaded = false
        issue = nil
    }
}
