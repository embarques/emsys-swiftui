import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDocumentModel: Identifiable {
    let id = UUID()
    let invoiceID: String
    private(set) var options: InvoiceSignatureOptions?
    private(set) var document: InvoiceDocument?
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var hasPendingChanges = false
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    init(invoiceID: String, client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.invoiceID = invoiceID
        self.client = client
        self.store = store
        self.isAuthorized = isAuthorized
    }

    var isAvailable: Bool { isAuthorized() }

    func refreshPendingChanges() async {
        guard isAuthorized() else { return }
        do {
            let pending = try await store.activeEdit(invoiceID: invoiceID) != nil
            if isAuthorized() { hasPendingChanges = pending }
        } catch {
            if isAuthorized() { failed = true }
        }
    }

    func load() async {
        guard !isLoading, isAuthorized() else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            let saved = try await store.latestDocument(invoiceID: invoiceID)
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            document = saved
            hasPendingChanges = try await store.activeEdit(invoiceID: invoiceID) != nil
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            struct Request: Encodable { let invoiceIds: [String] }
            let choices = try await client.post("reports/invoices/signature-options",
                body: Request(invoiceIds: [invoiceID]), as: [InvoiceSignatureOptions].self)
            guard choices.count == 1, let choice = choices.first, choice.invoiceID == invoiceID,
                  Set(choice.receiverSignatures.map(\.id)).count == choice.receiverSignatures.count else {
                throw DocumentError.invalidSelection
            }
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            options = choice
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() { failed = true }
        }
    }

    func generate(includeSender: Bool, receiverID: String, language: AppLanguage) async {
        guard !isLoading, isAuthorized(), let options,
              receiverID.isEmpty || options.receiverSignatures.contains(where: { $0.id == receiverID }) else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            hasPendingChanges = try await store.activeEdit(invoiceID: invoiceID) != nil
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            let selection = InvoiceSignatureSelection(invoiceID: invoiceID,
                includeSender: includeSender, receiverSignatureID: receiverID.isEmpty ? nil : receiverID)
            let generated = try await client.post("reports/invoices",
                body: InvoiceReportRequest(selections: [selection], language: language), as: GeneratedReport.self)
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            let pdf = try await ReportDownloader().download(generated.url)
            try Task.checkCancellation()
            guard isAuthorized() else { return }
            let saved = InvoiceDocument(id: UUID(), reportID: generated.reportID,
                selection: selection, savedAt: .now, pdf: pdf)
            try await store.saveDocument(saved)
            guard isAuthorized(), !Task.isCancelled else { return }
            document = saved
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() { failed = true }
        }
    }
}
