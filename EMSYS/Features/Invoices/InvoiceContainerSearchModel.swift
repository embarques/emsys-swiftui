import Foundation
import Observation

@MainActor
@Observable
final class InvoiceContainerSearchModel: Identifiable {
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
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
    }

    var isAvailable: Bool { isAuthorized() }

    func search(online: Bool) async {
        let request = UUID()
        requestID = request
        loadedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 0
        hasMore = false
        containers = []
        issue = nil
        isShowingDownloaded = true
        guard isAuthorized() else { isLoading = false; return }
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let saved = try await store.containers(matching: loadedQuery)
            guard isCurrent(request) else { return }
            containers = saved
            if online { try await fetch(page: 1, request: request) }
        } catch is CancellationError { return }
        catch { recordFailure(error, request: request) }
    }

    func loadMore(online: Bool) async {
        guard online, isAuthorized(), hasMore, !isLoading,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == loadedQuery else { return }
        let request = requestID
        isLoading = true
        issue = nil
        defer { if requestID == request { isLoading = false } }
        do { try await fetch(page: page + 1, request: request) }
        catch is CancellationError { return }
        catch { recordFailure(error, request: request) }
    }

    private func fetch(page requestedPage: Int, request: UUID) async throws {
        var queryItems = [URLQueryItem(name: "page", value: String(requestedPage)),
            URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "sort", value: "id:desc")]
        if !loadedQuery.isEmpty {
            queryItems += [URLQueryItem(name: "field", value: "name"),
                URLQueryItem(name: "operator", value: "contains"), URLQueryItem(name: "value", value: loadedQuery)]
        }
        let downloaded = try await client.get("containers", queryItems: queryItems, as: [InvoiceContainer]?.self) ?? []
        guard isCurrent(request) else { return }
        if requestedPage > 1 {
            let previousIDs = Set(containers.map(\.id))
            guard downloaded.allSatisfy({ !previousIDs.contains($0.id) }) else { throw APIClientError.invalidResponse }
        }
        try await store.saveContainers(downloaded)
        guard isCurrent(request) else { return }
        containers = requestedPage == 1 ? downloaded : containers + downloaded
        page = requestedPage
        isShowingDownloaded = false
        hasMore = downloaded.count == 40
    }

    private func isCurrent(_ request: UUID) -> Bool {
        requestID == request && isAuthorized() && !Task.isCancelled
    }

    private func recordFailure(_ error: Error, request: UUID) {
        guard isCurrent(request) else { return }
        if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
            containers = []
            hasMore = false
            issue = "auth.unavailable"
        } else {
            issue = "containers.searchError"
        }
    }
}
