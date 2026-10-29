import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDetailModel {
    private(set) var invoice: Invoice
    private(set) var isLoading = false
    private(set) var refreshFailed = false
    private(set) var pendingEdit: PendingInvoiceEdit?
    @ObservationIgnored private var printPreparation: Task<Void, Never>?
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore

    init(invoice: Invoice, client: APIClient, store: InvoiceStore) {
        self.invoice = invoice
        self.client = client
        self.store = store
    }

    func preparePrinting() async {
        if printPreparation == nil {
            printPreparation = Task {
                do { try await InvoiceLocalPrinting.prepare(client: client, store: store) }
                catch { printPreparation = nil; InvoiceLocalPrinting.logPreparationFailure(error) }
            }
        }
        await printPreparation?.value
    }

    func localPrintDocument(language: String, printedBy: String) async throws -> InvoiceDocument {
        // A background refresh must not delay printing already downloaded data.
        // Only first-use preparation waits for settings that are not cached yet.
        if try await store.printCompany() == nil {
            await printPreparation?.value
        }
        return try await InvoiceLocalPrinting.generate(invoiceID: invoice.id, store: store, language: language, printedBy: printedBy)
    }

    func makeDocumentModel(isAuthorized: @escaping () -> Bool) -> InvoiceDocumentModel {
        InvoiceDocumentModel(invoiceID: invoice.id, client: client, store: store, isAuthorized: isAuthorized)
    }

    func makeItemEditor(isAuthorized: @escaping () -> Bool) -> InvoiceItemEditorModel {
        InvoiceItemEditorModel(invoiceID: invoice.id, client: client, store: store, isAuthorized: isAuthorized)
    }

    func makePendingEdits(isAuthorized: @escaping () -> Bool, canEdit: @escaping () -> Bool) -> PendingInvoiceEditsModel {
        PendingInvoiceEditsModel(client: client, store: store, isAuthorized: isAuthorized, canEdit: canEdit)
    }

    func reloadSavedInvoice() async {
        guard !isLoading else { return }
        do {
            if let cached = try await store.invoice(id: invoice.id) {
                invoice = cached
                refreshFailed = false
            }
            pendingEdit = try await store.activeEdit(invoiceID: invoice.id)
        } catch {
            refreshFailed = true
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        refreshFailed = false
        defer { isLoading = false }
        do {
            if let cached = try await store.invoice(id: invoice.id) { invoice = cached }
            pendingEdit = try await store.activeEdit(invoiceID: invoice.id)
            try await InvoiceDetailDownloader(client: client, store: store).download(invoiceID: invoice.id)
            if let cached = try await store.invoice(id: invoice.id) { invoice = cached }
            pendingEdit = try await store.activeEdit(invoiceID: invoice.id)
        } catch is CancellationError {
            return
        } catch {
            refreshFailed = true
        }
    }
}
