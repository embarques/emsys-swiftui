import Foundation
import Observation

@MainActor
@Observable
final class InvoiceAssignmentPickerModel: Identifiable {
    let id = UUID()
    let source: InvoicePickupSource
    var query = ""
    private(set) var routes: [InvoicePickupRoute] = []
    private(set) var employees: [InvoicePickupEmployee] = []
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var issue: String?
    @ObservationIgnored private var branchTypes: [UInt16: String] = [:]
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canViewBranches: () -> Bool

    init(source: InvoicePickupSource, client: APIClient, store: InvoiceStore,
         isAuthorized: @escaping () -> Bool, canViewBranches: @escaping () -> Bool) {
        self.source = source
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
        self.canViewBranches = canViewBranches
    }

    var isAvailable: Bool { isAuthorized() }
    var matchingRoutes: [InvoicePickupRoute] {
        routes.filter { matches([$0.displayName, $0.route?.name ?? "", $0.date ?? ""]) }
    }
    var matchingEmployees: [InvoicePickupEmployee] {
        // The portal prefers source-specific roles, then falls back to active
        // employees outside delivery branches when no preferred role exists.
        let eligible = employees.filter {
            $0.isEligible && matches([$0.displayName, $0.branch?.name ?? "", $0.branch?.code ?? ""])
        }
        let preferred = eligible.filter { $0.matches(source, branchTypes: branchTypes) }
        return preferred.isEmpty ? eligible : preferred
    }

    func load(online: Bool) async {
        guard isAvailable, !isLoading else { return }
        isLoading = true
        isShowingDownloaded = true
        issue = nil
        defer { isLoading = false }
        do {
            if source == .route {
                let saved = try await store.pickupRoutes() ?? []
                guard isAvailable, !Task.isCancelled else { return }
                routes = saved
            } else {
                let saved = try await store.pickupEmployees() ?? []
                guard isAvailable, !Task.isCancelled else { return }
                employees = saved
                if canViewBranches(), let branches = try await store.pickupBranches() {
                    guard isAvailable, canViewBranches(), !Task.isCancelled else { return }
                    branchTypes = Dictionary(uniqueKeysWithValues: branches.map { ($0.id, $0.type ?? "") })
                }
            }
            guard online else { return }
            let downloader = InvoiceAssignmentDownloader(client: client)
            if source == .route {
                let downloaded = try await downloader.routes(isAuthorized: isAuthorized)
                guard isAvailable, !Task.isCancelled else { return }
                try await store.savePickupRoutes(downloaded)
                guard isAvailable, !Task.isCancelled else { return }
                routes = downloaded
            } else {
                let downloaded = try await downloader.employees(isAuthorized: isAuthorized)
                guard isAvailable, !Task.isCancelled else { return }
                try await store.savePickupEmployees(downloaded)
                guard isAvailable, !Task.isCancelled else { return }
                employees = downloaded
                if canViewBranches() {
                    do {
                        let branches = try await downloader.branches { isAvailable && canViewBranches() }
                        guard isAvailable, canViewBranches(), !Task.isCancelled else { return }
                        try await store.savePickupBranches(branches)
                        guard isAvailable, canViewBranches(), !Task.isCancelled else { return }
                        branchTypes = Dictionary(uniqueKeysWithValues: branches.map { ($0.id, $0.type ?? "") })
                    } catch {
                        // Branch metadata is optional. The portal's employee
                        // role/fallback rules still work without its catalog.
                        if !canViewBranches() { branchTypes = [:] }
                        if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                            branchTypes = [:]
                        }
                    }
                }
            }
            guard isAvailable, !Task.isCancelled else { return }
            isShowingDownloaded = false
        } catch is CancellationError { return }
        catch {
            guard isAvailable, !Task.isCancelled else { return }
            if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                routes = []
                employees = []
                issue = "auth.unavailable"
            } else { issue = "pickupAssignment.loadError" }
        }
    }

    private func matches(_ values: [String]) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || values.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
