import Foundation
import Observation

@MainActor
@Observable
final class InvoiceContainerSearchViewModel: Identifiable {
    let id = UUID()
    var query = ""
    private(set) var containers: [InvoiceContainer] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var hasMore = false
    private(set) var issue: String?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var loadedQuery = ""
    @ObservationIgnored private var page = 0
    @ObservationIgnored private let repository: InvoiceDraftRepository
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    /// Opens the container picker with the current session and offline store.
    init(client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.repository = InvoiceDraftRepository(store: store, client: client)
        self.store = store
        self.isAuthorized = isAuthorized
    }

    /// Checks whether this session can keep the picker open.
    var isAvailable: Bool { isAuthorized() }

    /// Opens the cached container results and refreshes them when connected.
    func search(online: Bool) async {
        // A new query supersedes any response still in flight.
        let request = UUID()
        requestID = request
        loadedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 0
        hasMore = false
        containers = []
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
            let saved = try await store.containers(matching: loadedQuery)
            guard isCurrent(request) else {
                return
            }
            containers = saved
            if online {
                try await fetch(page: 1, request: request)
            }
        } catch is CancellationError {
            return
        }
        catch {
            recordFailure(error, request: request)
        }
    }

    /// Appends the next page for the current search.
    func loadMore(online: Bool) async {
        guard online, isAuthorized(), hasMore, !isLoading,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == loadedQuery else {
            return
        }
        let request = requestID
        isLoading = true
        issue = nil
        defer {
            // Only the current request can clear its loading state.
            if requestID == request {
                isLoading = false
            }
        }
        do {
            try await fetch(page: page + 1, request: request)
        }
        catch is CancellationError {
            return
        }
        catch {
            recordFailure(error, request: request)
        }
    }

    /// Loads and displays the requested container page.
    private func fetch(page requestedPage: Int, request: UUID) async throws {
        // The first remote page replaces the cached results.
        let previousIDs: Set<UInt32>
        if requestedPage == 1 {
            previousIDs = []
        } else {
            previousIDs = Set(containers.map(\.id))
        }
        let downloaded = try await repository.searchContainers(term: loadedQuery, page: requestedPage,
            previousIDs: previousIDs) {
                self.isCurrent(request)
            }
        guard isCurrent(request) else {
            return
        }
        if requestedPage == 1 {
            containers = downloaded
        } else {
            containers.append(contentsOf: downloaded)
        }
        page = requestedPage
        isShowingDownloaded = false
        hasMore = downloaded.count == InvoiceDraftRepository.containerPageSize
    }

    /// Checks if the request still belongs to the active search and session.
    private func isCurrent(_ request: UUID) -> Bool {
        requestID == request && isAuthorized() && !Task.isCancelled
    }

    /// Updates the current search after a download fails.
    private func recordFailure(_ error: Error, request: UUID) {
        guard isCurrent(request) else {
            return
        }
        if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
            containers = []
            hasMore = false
            issue = "auth.unavailable"
        } else {
            issue = "containers.searchError"
        }
    }
}
