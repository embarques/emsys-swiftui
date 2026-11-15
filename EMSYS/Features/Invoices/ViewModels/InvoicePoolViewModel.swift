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
    @ObservationIgnored private let repository: InvoicePoolRepository
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canGenerate: () -> Bool

    /// Opens the reservation screen within the current tenant and device scope.
    init(repository: InvoicePoolRepository, canGenerate: @escaping () -> Bool, isAuthorized: @escaping () -> Bool) {
        self.repository = repository
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
        // Ignore overlapping loads and avoid reading outside the active session.
        guard isAvailable, !isLoading else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        issue = nil
        await loadLocal()
        do {
            // Refresh through the repository after presenting the local snapshot.
            let didRefresh = try await repository.refresh(isAuthorized: isAuthorized)
            if !didRefresh {
                return
            }
        } catch {
            // A session that lost access should not receive a stale error.
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
        // An unresolved action must be reconciled before staging another one.
        guard isAvailable, !isLoading, pendingCount == 0, kind != .generate || canGenerate() else {
            return
        }
        isLoading = true
        defer {
            isLoading = false
        }
        issue = nil
        do {
            // The repository stages the intent before attempting network work.
            try await repository.submit(kind, items: items, isAuthorized: isAuthorized)
        } catch {
            // Publish errors only while the screen still belongs to the session.
            if isAvailable {
                issue = "invoicePool.syncError"
            }
        }
        await loadLocal()
    }

    /// Presents the available reservations and pending actions from the local snapshot.
    private func loadLocal() async {
        // A revoked session cannot read the local snapshot.
        guard isAvailable else {
            return
        }
        do {
            let status = try await repository.status()

            // Never display numbers from a session that changed during the read.
            guard isAvailable, !Task.isCancelled else {
                return
            }
            available = status.available
            reservations = status.reservations
            threshold = status.threshold
            pendingCount = status.pendingCount
        } catch {
            // Publish errors only while the screen still belongs to the session.
            if isAvailable {
                issue = "invoicePool.loadError"
            }
        }
    }
}
