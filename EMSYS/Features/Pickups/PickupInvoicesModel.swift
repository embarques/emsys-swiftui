import Foundation
import Observation

nonisolated struct PickupInvoiceLink: Identifiable, Sendable {
    let id: String
    let invoiceID: String?
    let number: String?
    let state: PendingInvoiceCreation.State?
}

@MainActor
@Observable
final class PickupInvoicesModel {
    private(set) var links: [PickupInvoiceLink] = []
    private(set) var didLoad = false
    private(set) var issue: String?
    @ObservationIgnored private let pickupID: UInt32
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let canEdit: () -> Bool

    init(pickupID: UInt32, store: InvoiceStore, client: APIClient,
         isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) {
        self.pickupID = pickupID
        self.store = store
        self.client = client
        self.isAuthorized = isAuthorized
        self.canEdit = canEdit
    }

    var mayCreate: Bool { isAuthorized() && didLoad && issue == nil && links.isEmpty }
    var mayEdit: Bool { isAuthorized() && canEdit() }

    func load() async {
        guard isAuthorized() else { links = []; didLoad = false; return }
        do {
            let saved = try await store.pickupInvoiceLinks(pickupID: pickupID)
            guard isAuthorized(), !Task.isCancelled else { return }
            links = saved
            issue = nil
            didLoad = true
        } catch {
            guard isAuthorized(), !Task.isCancelled else { return }
            issue = "pickups.invoiceLinksError"
        }
    }

    func editor(for link: PickupInvoiceLink) -> InvoiceItemEditorModel? {
        guard mayEdit, let saved = links.first(where: { $0.id == link.id }),
              let invoiceID = saved.invoiceID else { return nil }
        return InvoiceItemEditorModel(invoiceID: invoiceID, client: client, store: store,
            isAuthorized: { self.isAuthorized() && self.canEdit() })
    }
}
