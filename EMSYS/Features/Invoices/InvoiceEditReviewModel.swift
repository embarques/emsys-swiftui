import Foundation
import Observation

@MainActor
@Observable
final class InvoiceEditReviewModel {
    private(set) var edit: PendingInvoiceEdit
    private(set) var latest: InvoiceEditSnapshot?
    private(set) var isLoading = false
    private(set) var isResolving = false
    private(set) var didResolve = false
    private(set) var hasReplacement = false
    private(set) var issue: String?
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canEdit: () -> Bool

    init(edit: PendingInvoiceEdit, client: APIClient, store: InvoiceStore,
         isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) {
        self.edit = edit
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
        self.canEdit = canEdit
    }

    var isAvailable: Bool { isAuthorized() }
    var canResolve: Bool { edit.state == .needsReview && latest != nil && !isLoading && !isResolving && isAuthorized() }
    var canKeepLocal: Bool {
        guard canResolve, canEdit(), let latest else { return false }
        let currentIDs = Set(latest.invoice.items.map(\.id))
        return edit.changes.allSatisfy { currentIDs.contains($0.itemID) }
    }

    func serverName(itemID: String) -> String? {
        latest?.invoice.items.first { $0.id == itemID }?.name
    }

    func load(allowNetwork: Bool) async {
        guard !isLoading, !isResolving, isAuthorized() else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            guard let current = try await store.activeEdit(invoiceID: edit.invoiceID), current.id == edit.id else {
                if isAuthorized() { didResolve = true }
                return
            }
            guard isAuthorized(), !Task.isCancelled else { return }
            edit = current
            guard current.state == .needsReview else { return }
            if let saved = try await store.editSnapshot(invoiceID: edit.invoiceID), saved.revision != edit.expectedRevision {
                latest = saved
            }
            if allowNetwork {
                let version = try await store.downloadVersion()
                let snapshot = try await client.get("invoices/sync/\(edit.invoiceID)", as: InvoiceEditSnapshot.self)
                try snapshot.validate(invoiceID: edit.invoiceID)
                try Task.checkCancellation()
                guard isAuthorized() else { return }
                try await store.saveEditSnapshot(snapshot, ifUnchangedSince: version)
                latest = snapshot
            } else if latest == nil {
                issue = "invoiceEdits.reviewUnavailable"
            }
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() { issue = "invoiceEdits.reviewUnavailable" }
        }
    }

    func resolve(keepLocalNames: Bool) async {
        guard canResolve, !keepLocalNames || canKeepLocal, let latest else { return }
        isResolving = true
        issue = nil
        defer { isResolving = false }
        do {
            let replacement = try await store.resolveEdit(editID: edit.id, latest: latest, keepLocalNames: keepLocalNames)
            guard isAuthorized() else { return }
            hasReplacement = replacement != nil
            didResolve = true
        } catch {
            if isAuthorized() { issue = "invoiceEdits.resolveFailed" }
        }
    }
}
