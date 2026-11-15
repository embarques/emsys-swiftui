import Foundation
import Observation

@MainActor
@Observable
final class InvoiceEditReviewViewModel {
    private(set) var edit: PendingInvoiceEdit
    private(set) var latest: InvoiceEditSnapshot?
    private(set) var isLoading = false
    private(set) var isResolving = false
    private(set) var didResolve = false
    private(set) var hasReplacement = false
    private(set) var issue: String?
    @ObservationIgnored private let downloader: InvoiceDetailDownloader
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canEdit: () -> Bool

    /// Opens the pending edit under the current session and edit grant.
    init(edit: PendingInvoiceEdit, client: APIClient, store: InvoiceStore,
         isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) {
        self.edit = edit
        self.downloader = InvoiceDetailDownloader(client: client, store: store)
        self.store = store
        self.isAuthorized = isAuthorized
        self.canEdit = canEdit
    }

    /// Checks whether the session still permits viewing this conflict.
    var isAvailable: Bool { isAuthorized() }
    /// Checks whether a server version is ready for conflict review.
    var canResolve: Bool { edit.state == .needsReview && latest != nil && !isLoading && !isResolving && isAuthorized() }
    /// Checks whether the server still has every item changed locally.
    var canKeepLocal: Bool {
        guard canResolve, canEdit(), let latest else {
            return false
        }
        let currentIDs = Set(latest.invoice.items.map(\.id))
        return edit.changes.allSatisfy { currentIDs.contains($0.itemID) }
    }

    /// Returns the current server label for a changed invoice item.
    func serverName(itemID: String) -> String? {
        latest?.invoice.items.first { $0.id == itemID }?.name
    }

    /// Loads the pending edit and refreshes the version used for review.
    func load(allowNetwork: Bool) async {
        guard !isLoading, !isResolving, isAuthorized() else {
            return
        }
        isLoading = true
        issue = nil
        defer {
            isLoading = false
        }
        do {
            // The outbox may have resolved this edit while review was being opened.
            guard let current = try await store.activeEdit(invoiceID: edit.invoiceID), current.id == edit.id else {
                if isAuthorized() {
                    didResolve = true
                }
                return
            }
            guard isAuthorized(), !Task.isCancelled else {
                return
            }
            edit = current
            guard current.state == .needsReview else {
                return
            }
            if let saved = try await store.editSnapshot(invoiceID: edit.invoiceID), saved.revision != edit.expectedRevision {
                latest = saved
            }
            if allowNetwork {
                // Only a versioned response can resolve an edit conflict.
                latest = try await downloader.downloadSnapshot(invoiceID: edit.invoiceID,
                    isAuthorized: isAuthorized)
            } else if latest == nil {
                issue = "invoiceEdits.reviewUnavailable"
            }
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() {
                issue = "invoiceEdits.reviewUnavailable"
            }
        }
    }

    /// Commits a conflict decision and records whether a replacement is queued.
    func resolve(keepLocalNames: Bool) async {
        guard canResolve, !keepLocalNames || canKeepLocal, let latest else {
            return
        }
        isResolving = true
        issue = nil
        defer {
            isResolving = false
        }
        do {
            // The store validates and records the user's decision in one transaction.
            let replacement = try await store.resolveEdit(editID: edit.id, latest: latest, keepLocalNames: keepLocalNames)
            guard isAuthorized() else {
                return
            }
            hasReplacement = replacement != nil
            didResolve = true
        } catch {
            if isAuthorized() {
                issue = "invoiceEdits.resolveFailed"
            }
        }
    }
}
