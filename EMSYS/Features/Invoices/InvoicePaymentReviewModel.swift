import Foundation
import Observation

@MainActor
@Observable
final class InvoicePaymentReviewModel: Identifiable {
    let id = UUID()
    let branchID: UInt16?
    let day: InvoiceDate
    private(set) var review: InvoicePaymentReview?
    private(set) var isLoading = false
    private(set) var isShowingDownloaded = true
    private(set) var issue: String?
    private(set) var accessDenied = false
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let currentBranchID: () -> UInt16?

    init(day: InvoiceDate = InvoiceDate(date: .now), client: APIClient, store: InvoiceStore,
         isAuthorized: @escaping () -> Bool, currentBranchID: @escaping () -> UInt16?) {
        self.day = day
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
        self.currentBranchID = currentBranchID
        branchID = currentBranchID()
    }

    var isAvailable: Bool { !accessDenied && isAuthorized() && branchID == currentBranchID() }
    var canSelect: Bool {
        isAvailable && !isLoading && review?.isValid == true && review?.statement?.isOpen == true
    }

    func load(online: Bool) async {
        guard isAvailable, !isLoading else { return }
        guard let branchID, branchID > 0, day.pickerDate != nil else { issue = "paymentReview.missingBranch"; return }
        isLoading = true
        isShowingDownloaded = true
        issue = nil
        defer { isLoading = false }
        do {
            let saved = try await store.paymentReview(branchID: branchID, day: day)
            guard isAvailable, !Task.isCancelled else { return }
            review = saved
            guard online else {
                if saved == nil { issue = "paymentReview.notDownloaded" }
                return
            }
            let statements = try await client.post("income-statements/search",
                body: InvoiceIncomeStatementQuery(branchID: branchID, day: day), as: [InvoiceIncomeStatement]?.self) ?? []
            guard isAvailable, !Task.isCancelled else { return }
            guard statements.count <= 1, statements.allSatisfy({ $0.matches(branchID: branchID, day: day) }) else {
                throw APIClientError.invalidResponse
            }
            let downloaded = InvoicePaymentReview(branchID: branchID, day: day, statement: statements.first, downloadedAt: .now)
            try await store.savePaymentReview(downloaded)
            guard isAvailable, !Task.isCancelled else { return }
            review = downloaded
            isShowingDownloaded = false
        } catch is CancellationError { return }
        catch {
            guard isAvailable, !Task.isCancelled else { return }
            if let error = error as? APIClientError, error == .httpStatus(403) || error == .httpStatus(401) {
                review = nil
                accessDenied = true
                issue = "auth.unavailable"
            } else { issue = "paymentReview.loadError" }
        }
    }
}
