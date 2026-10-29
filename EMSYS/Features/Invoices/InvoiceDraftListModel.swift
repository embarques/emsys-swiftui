import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDraftListModel: Identifiable {
    let id = UUID()
    private(set) var drafts: [InvoiceDraftSummary] = []
    private(set) var page = 1
    private(set) var isLoading = false
    private(set) var issue: String?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let client: APIClient?
    @ObservationIgnored private let canViewItemCatalog: () -> Bool
    @ObservationIgnored private let canViewCustomers: () -> Bool
    @ObservationIgnored private let canReviewPolicies: () -> Bool
    @ObservationIgnored private let canViewContainers: () -> Bool
    @ObservationIgnored private let canViewAssignments: (InvoiceAssignmentPermission) -> Bool
    @ObservationIgnored private let canReviewPayments: () -> Bool
    @ObservationIgnored private let financialPermission: (InvoiceFinancialPermission) -> Bool
    @ObservationIgnored private let currentBranchID: () -> UInt16?
    let assignedOnly: Bool

    init(assignedOnly: Bool = false, store: InvoiceStore, client: APIClient? = nil, canViewItemCatalog: @escaping () -> Bool = { false },
         canViewCustomers: @escaping () -> Bool = { false },
         canReviewPolicies: @escaping () -> Bool = { false },
         canViewContainers: @escaping () -> Bool = { false },
         canViewAssignments: @escaping (InvoiceAssignmentPermission) -> Bool = { _ in false },
         canReviewPayments: @escaping () -> Bool = { false }, currentBranchID: @escaping () -> UInt16? = { nil },
         financialPermission: @escaping (InvoiceFinancialPermission) -> Bool = { _ in false },
         isAuthorized: @escaping () -> Bool) {
        self.assignedOnly = assignedOnly
        self.store = store
        self.isAuthorized = isAuthorized
        self.client = client
        self.canViewItemCatalog = canViewItemCatalog
        self.canViewCustomers = canViewCustomers
        self.canReviewPolicies = canReviewPolicies
        self.canViewContainers = canViewContainers
        self.canViewAssignments = canViewAssignments
        self.canReviewPayments = canReviewPayments
        self.currentBranchID = currentBranchID
        self.financialPermission = financialPermission
    }

    var isAvailable: Bool { isAuthorized() }

    func editor(draftID: UUID? = nil) -> InvoiceDraftEditorModel {
        InvoiceDraftEditorModel(assignedOnlyAccess: assignedOnly, draftID: draftID, store: store, client: client,
            canViewItemCatalog: canViewItemCatalog, canViewCustomers: canViewCustomers, canReviewPolicies: canReviewPolicies,
            canViewContainers: canViewContainers, canViewAssignments: canViewAssignments,
            canReviewPayments: canReviewPayments, currentBranchID: currentBranchID, financialPermission: financialPermission, isAuthorized: isAuthorized)
    }

    func load(page: Int? = nil) async {
        guard isAuthorized() else { return }
        if let page { self.page = max(1, page) }
        let request = UUID()
        requestID = request
        isLoading = true
        issue = nil
        defer { if requestID == request { isLoading = false } }
        do {
            let saved = try await store.draftSummaries(offset: (self.page - 1) * 40, assignedOnly: assignedOnly)
            guard requestID == request, isAuthorized(), !Task.isCancelled else { return }
            drafts = saved
        } catch {
            if requestID == request, isAuthorized(), !Task.isCancelled { issue = "drafts.loadError" }
        }
    }

    func delete(_ draft: InvoiceDraftSummary) async {
        guard isAuthorized(), !isLoading else { return }
        do {
            try await store.deleteDraft(id: draft.id, expectedRevision: draft.revision)
            await load()
        } catch {
            if isAuthorized() { issue = "drafts.deleteError" }
        }
    }
}
