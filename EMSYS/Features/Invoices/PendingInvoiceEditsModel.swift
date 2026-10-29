import Foundation
import Observation

@MainActor
@Observable
final class PendingInvoiceEditsModel: Identifiable {
    let id = UUID()
    private(set) var edits: [PendingInvoiceEdit] = []
    private(set) var page = 1
    private(set) var isLoading = false
    private(set) var failed = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canEdit: () -> Bool

    init(client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) {
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
        self.canEdit = canEdit
    }

    var isAvailable: Bool { isAuthorized() }

    func load(page: Int? = nil) async {
        guard isAuthorized() else { return }
        if let page { self.page = max(1, page) }
        let currentRequest = UUID()
        requestID = currentRequest
        isLoading = true
        failed = false
        defer { if requestID == currentRequest { isLoading = false } }
        do {
            let downloaded = try await store.activeEdits(offset: (self.page - 1) * 40)
            guard requestID == currentRequest, isAuthorized(), !Task.isCancelled else { return }
            edits = downloaded
        } catch {
            if requestID == currentRequest, isAuthorized(), !Task.isCancelled { failed = true }
        }
    }

    func review(_ edit: PendingInvoiceEdit) -> InvoiceEditReviewModel {
        InvoiceEditReviewModel(edit: edit, client: client, store: store, isAuthorized: isAuthorized, canEdit: canEdit)
    }
}
