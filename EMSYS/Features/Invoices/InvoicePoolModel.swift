import Foundation
import Observation

@MainActor
@Observable
final class InvoicePoolModel: Identifiable {
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

    init(store: InvoiceStore, client: APIClient?, canGenerate: @escaping () -> Bool, isAuthorized: @escaping () -> Bool) {
        self.store = store
        self.client = client
        self.canGenerate = canGenerate
        self.isAuthorized = isAuthorized
    }
    var isAvailable: Bool { isAuthorized() }
    var canGenerateNumbers: Bool { isAvailable && canGenerate() && !isLoading && pendingCount == 0 }
    var isLow: Bool { available <= threshold }

    func load() async {
        guard isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        issue = nil
        await loadLocal()
        guard let client, isAvailable else { return }
        do {
            let sync = InvoicePoolSynchronizer(client: client, store: store)
            try await sync.synchronizeActions()
            try await sync.downloadCurrentPool()
        } catch { if isAvailable { issue = "invoicePool.syncError" } }
        await loadLocal()
    }

    func downloadAssignments() async { await perform(.claim) }
    func generateNumbers() async {
        guard canGenerateNumbers else { return }
        await perform(.generate)
        guard issue == nil, isAvailable else { return }
        await perform(.claim)
    }
    func returnNumber(_ reservation: InvoiceReservation) async { await perform(.return, items: [reservation]) }

    private func perform(_ kind: InvoicePoolAction.Kind, items: [InvoiceReservation] = []) async {
        guard isAvailable, !isLoading, pendingCount == 0, kind != .generate || canGenerate() else { return }
        isLoading = true
        defer { isLoading = false }
        issue = nil
        do {
            let deviceID = try await store.invoicePoolDeviceID()
            let action = InvoicePoolAction(action: kind, deviceID: deviceID, items: items)
            try await store.stageInvoicePoolAction(action)
            guard let client, isAvailable else { throw APIClientError.invalidResponse }
            let sync = InvoicePoolSynchronizer(client: client, store: store)
            try await sync.synchronizeActions()
            try await sync.downloadCurrentPool()
        } catch { if isAvailable { issue = "invoicePool.syncError" } }
        await loadLocal()
    }

    private func loadLocal() async {
        guard isAvailable else { return }
        do {
            let count = try await store.availableInvoiceReservationCount()
            let rows = try await store.availableInvoiceReservations()
            let lowThreshold = try await store.invoicePoolThreshold()
            let actions = try await store.pendingInvoicePoolActions()
            guard isAvailable, !Task.isCancelled else { return }
            available = count; reservations = rows; threshold = lowThreshold; pendingCount = actions.count
        } catch { if isAvailable { issue = "invoicePool.loadError" } }
    }
}
