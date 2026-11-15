import Foundation
import Observation

@MainActor
@Observable
final class InvoicePoolViewModel: Identifiable {
    let id = UUID()
    private(set) var available = 0
    private(set) var threshold = 10
    private(set) var reservations: [InvoiceReservation] = []
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var pendingCount = 0
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let client: APIClient?
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canGenerate: () -> Bool

    /// Opens the reservation screen within the current tenant and device scope.
    init(store: InvoiceStore, client: APIClient?, canGenerate: @escaping () -> Bool, isAuthorized: @escaping () -> Bool) {
        self.store = store
        self.client = client
        self.canGenerate = canGenerate
        self.isAuthorized = isAuthorized
    }
    /// Checks whether this session may view its reserved numbers.
    var isAvailable: Bool { isAuthorized() }
    /// Checks permission and whether a previous action still needs synchronization.
    var canGenerateNumbers: Bool { isAvailable && canGenerate() && !isLoading && pendingCount == 0 }
    /// Checks the locally saved low-number threshold.
    var isLow: Bool { available <= threshold }

    /// Restores local numbers and then tries to reconcile the server pool.
    func load() async {
        guard isAvailable, !isLoading else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        issue = nil
        await loadLocal()
        guard let client, isAvailable else {
            return
        }
        do {
            let sync = InvoicePoolSynchronizer(client: client, store: store)
            try await sync.synchronizeActions()
            try await sync.downloadCurrentPool()
        } catch {
            if isAvailable {
                issue = "invoicePool.syncError"
            }
        }
        await loadLocal()
    }

    /// Claims numbers already assigned to this account.
    func downloadAssignments() async { await perform(.claim) }
    /// Generates a batch and then claims it for this device.
    func generateNumbers() async {
        guard canGenerateNumbers else {
            return
        }
        await perform(.generate)
        guard issue == nil, isAvailable else {
            return
        }
        await perform(.claim)
    }
    /// Stages the return of an unused reserved number.
    func returnNumber(_ reservation: InvoiceReservation) async { await perform(.return, items: [reservation]) }

    /// Persists the reservation intent before attempting online synchronization.
    private func perform(_ kind: InvoicePoolAction.Kind, items: [InvoiceReservation] = []) async {
        guard isAvailable, !isLoading, pendingCount == 0, kind != .generate || canGenerate() else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        issue = nil
        do {
            let deviceID = try await store.invoicePoolDeviceID()
            let action = InvoicePoolAction(action: kind, deviceID: deviceID, items: items)
            // Save the intent first so retries resume it with the same request identity.
            try await store.stageInvoicePoolAction(action)
            guard let client, isAvailable else {
                throw APIClientError.invalidResponse
            }
            let sync = InvoicePoolSynchronizer(client: client, store: store)
            try await sync.synchronizeActions()
            try await sync.downloadCurrentPool()
        } catch {
            if isAvailable {
                issue = "invoicePool.syncError"
            }
        }
        await loadLocal()
    }

    /// Presents the available reservations and pending actions from the local snapshot.
    private func loadLocal() async {
        guard isAvailable else {
            return
        }
        do {
            let status = try await store.invoicePoolStatus()

            // Never display numbers from a session that changed during the read.
            guard isAvailable, !Task.isCancelled else {
                return
            }
            available = status.available
            reservations = status.reservations
            threshold = status.threshold
            pendingCount = status.pendingCount
        } catch {
            if isAvailable {
                issue = "invoicePool.loadError"
            }
        }
    }
}
