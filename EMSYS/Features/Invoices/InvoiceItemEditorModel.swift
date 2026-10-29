import Foundation
import Observation

@MainActor
@Observable
final class InvoiceItemEditorModel: Identifiable {
    struct Item: Identifiable {
        let id: String
        var name: String
    }

    let id = UUID()
    let invoiceID: String
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var queuedEdit: PendingInvoiceEdit?
    private(set) var issue: String?
    @ObservationIgnored private var originalNames: [String: String] = [:]
    @ObservationIgnored private var baseSnapshot: InvoiceEditSnapshot?
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(invoiceID: String, client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.invoiceID = invoiceID
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
    }

    var hasChanges: Bool { items.contains { originalNames[$0.id] != $0.name } }
    var mayEdit: Bool { isAuthorized() }
    var canSave: Bool {
        isAuthorized() && !isLoading && !isSaving && hasChanges
            && items.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func setName(_ name: String, itemID: String) {
        guard !isSaving, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].name = name
    }

    func load() async {
        guard !isLoading, isAuthorized() else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            guard try await store.activeEdit(invoiceID: invoiceID) == nil else {
                issue = "invoiceEdits.alreadyPending"
                return
            }
            if try await store.editSnapshot(invoiceID: invoiceID) == nil {
                try await InvoiceDetailDownloader(client: client, store: store).download(invoiceID: invoiceID)
            }
            guard let snapshot = try await store.editSnapshot(invoiceID: invoiceID) else {
                throw InvoiceStore.StoreError.missingEditSnapshot
            }
            try Task.checkCancellation()
            guard isAuthorized(), Set(snapshot.invoice.items.map(\.id)).count == snapshot.invoice.items.count else { return }
            items = snapshot.invoice.items.map { Item(id: $0.id, name: $0.name) }
            baseSnapshot = snapshot
            originalNames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
            if items.isEmpty { issue = "invoiceEdits.unavailable" }
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() { issue = "invoiceEdits.unavailable" }
        }
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        issue = nil
        defer { isSaving = false }
        do {
            guard let baseSnapshot else { throw InvoiceStore.StoreError.missingEditSnapshot }
            let names = Dictionary(uniqueKeysWithValues: items.filter { originalNames[$0.id] != $0.name }.map { ($0.id, $0.name) })
            let edit = try await store.queueItemNames(invoiceID: invoiceID, names: names, basedOn: baseSnapshot)
            guard isAuthorized() else { return }
            queuedEdit = edit
            didSave = true
        } catch InvoiceWriteDocument.WriteError.noChanges {
            if isAuthorized() { didSave = true }
        } catch InvoiceStore.StoreError.editAlreadyPending {
            if isAuthorized() { issue = "invoiceEdits.alreadyPending" }
        } catch {
            if isAuthorized() { issue = "invoiceEdits.saveFailed" }
        }
    }
}
