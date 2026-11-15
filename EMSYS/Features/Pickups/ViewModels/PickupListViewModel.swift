import Foundation
import Observation

@MainActor
@Observable
final class PickupListViewModel {
    private(set) var pickups: [Pickup] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = false
    private(set) var issue: String?
    private(set) var hasMore = false
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var query = PickupListQuery()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let repository: PickupRepository
    @ObservationIgnored private let isAuthorized: () -> Bool

    /// Creates the directory with the current user’s pickup repository.
    init(client: APIClient, store: PickupStore, isAuthorized: @escaping () -> Bool) {
        repository = PickupRepository(client: client, store: store)
        self.isAuthorized = isAuthorized
    }

    /// Resets the search and displays local data before requesting the first page.
    func load(query: PickupListQuery, online: Bool) async {
        // Assign a fresh token so a late page cannot replace this search.
        let token = UUID()
        generation = token
        self.query = query
        page = 0
        pickups = []
        hasMore = false
        issue = nil
        // The authenticated session owns both the local snapshot and the network request.
        guard isAuthorized() else {
            return
        }
        isLoading = true
        defer {
            if generation == token {
                isLoading = false
            }
        }
        do {
            // Local records render before the network request; a failed refresh
            // leaves them available without pretending the server was reached.
            let cached = try await repository.store.pickups(matching: query)
            guard generation == token, isAuthorized(), !Task.isCancelled else {
                return
            }
            pickups = cached
            isShowingDownloaded = true
            if online {
                try await fetch(page: 1, token: token)
            }
        } catch is CancellationError {
            // A superseded search has no error to present.
        } catch {
            await handleFailure(error, token: token)
        }
    }

    /// Fetches the next server page when the current search can continue.
    func loadMore() async {
        // Prevent overlapping requests for the same page.
        guard isAuthorized(), !isLoading, hasMore else {
            return
        }
        let token = generation
        isLoading = true
        defer {
            if generation == token {
                isLoading = false
            }
        }
        do {
            try await fetch(page: page + 1, token: token)
        } catch is CancellationError {
            // A newer search owns the list after cancellation.
        } catch {
            await handleFailure(error, token: token)
        }
    }

    /// Opens a pickup detail under the same data scope as the directory.
    func detail(_ pickup: Pickup, canUpdate: @escaping () -> Bool) -> PickupDetailViewModel {
        PickupDetailViewModel(pickup: pickup, client: repository.client, store: repository.store,
                              isAuthorized: isAuthorized, canUpdate: canUpdate)
    }

    /// Preserves offline data on network failure and hides it after a permission denial.
    private func handleFailure(_ error: Error, token: UUID) async {
        // Errors from a previous search cannot change the current list.
        guard generation == token, isAuthorized(), !Task.isCancelled else {
            return
        }
        if case APIClientError.httpStatus(let status) = error, status == 401 || status == 403 {
            // The store hides downloaded records while retaining pending operations.
            pickups = []
            hasMore = false
            try? await repository.store.removeAll()
        }
        guard generation == token, isAuthorized(), !Task.isCancelled else {
            return
        }
        if !AuthenticationSession.permitsOfflineRestoration(error) {
            issue = "pickups.refreshError"
        }
    }

    /// Publishes a downloaded page after the repository has persisted and projected it.
    private func fetch(page: Int, token: UUID) async throws {
        let requestedQuery = query
        let result = try await repository.downloadPage(query: requestedQuery, page: page) {
            self.generation == token && self.isAuthorized()
        }

        // A prior search may finish after the user changes the query or account.
        guard generation == token, isAuthorized(), !Task.isCancelled else {
            return
        }

        // Keep local completions visible even when they are absent from the server page.
        if page == 1 {
            let cached = try await repository.store.pickups(matching: requestedQuery)
            guard generation == token, isAuthorized(), !Task.isCancelled else {
                return
            }
            pickups = cached.filter { $0.pendingCompletion == true }
        }

        // Append in server order and keep each pickup visible once.
        var displayedIDs = Set(pickups.map(\.id))
        for pickup in result.pickups {
            guard requestedQuery.matches(pickup), displayedIDs.insert(pickup.id).inserted else {
                continue
            }
            pickups.append(pickup)
        }
        self.page = page
        hasMore = result.hasMore
        isShowingDownloaded = false
        issue = nil
    }
}
