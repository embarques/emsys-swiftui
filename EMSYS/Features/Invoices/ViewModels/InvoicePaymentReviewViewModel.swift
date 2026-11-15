import Foundation
import Observation

@MainActor
@Observable
final class InvoicePaymentReviewViewModel: Identifiable {
    let id = UUID()
    let branchID: UInt16?
    let day: InvoiceDate
    private(set) var review: InvoicePaymentReview?
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var issue: String?
    private(set) var accessDenied = false
    @ObservationIgnored private let repository: InvoiceDraftRepository
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let currentBranchID: () -> UInt16?

    /// Captures the selected branch and business day for this review.
    init(day: InvoiceDate = InvoiceDate(date: .now), repository: InvoiceDraftRepository, store: InvoiceStore,
         isAuthorized: @escaping () -> Bool, currentBranchID: @escaping () -> UInt16?) {
        self.day = day
        self.repository = repository
        self.store = store
        self.isAuthorized = isAuthorized
        self.currentBranchID = currentBranchID
        branchID = currentBranchID()
    }

    /// Checks that the selected branch and authorization are still current.
    var isAvailable: Bool { !accessDenied && isAuthorized() && branchID == currentBranchID() }
    /// Checks whether the downloaded statement can be attached to the draft.
    var canSelect: Bool {
        isAvailable && !isLoading && review?.isValid == true && review?.statement?.isOpen == true
    }

    /// Restores the cached review and refreshes it when connected.
    func load(online: Bool) async {
        guard isAvailable, !isLoading else {
            return
        }
        guard let branchID, branchID > 0, day.pickerDate != nil else {
            issue = "paymentReview.missingBranch"
            return
        }

        isLoading = true
        isShowingDownloaded = true
        issue = nil
        defer {
            isLoading = false
        }

        do {
            // Restore the last review so the operator can work without connectivity.
            let saved = try await store.paymentReview(branchID: branchID, day: day)
            guard isAvailable, !Task.isCancelled else {
                return
            }
            review = saved
            guard online else {
                if saved == nil {
                    issue = "paymentReview.notDownloaded"
                }
                return
            }

            // A branch or session change invalidates the pending download.
            let downloaded = try await repository.refreshPaymentReview(branchID: branchID, day: day) {
                self.isAvailable
            }
            guard isAvailable, !Task.isCancelled else {
                return
            }
            review = downloaded
            isShowingDownloaded = false
        } catch is CancellationError {
            return
        } catch {
            guard isAvailable, !Task.isCancelled else {
                return
            }

            // An explicit denial revokes access to the cached statement as well.
            if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                review = nil
                accessDenied = true
                issue = "auth.unavailable"
            } else {
                issue = "paymentReview.loadError"
            }
        }
    }
}
