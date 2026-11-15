import Foundation

/// Downloads authorized invoice reports and keeps the confirmed PDF available offline.
@MainActor
struct InvoiceDocumentRepository {
    let client: APIClient
    let store: InvoiceStore

    private struct SignatureOptionsRequest: Encodable {
        let invoiceIds: [String]
    }

    /// Loads signature choices and validates that the response belongs to this invoice.
    func signatureOptions(invoiceID: String) async throws -> InvoiceSignatureOptions {
        let request = SignatureOptionsRequest(invoiceIds: [invoiceID])
        let results = try await client.post("reports/invoices/signature-options",
            body: request, as: [InvoiceSignatureOptions].self)

        // A single-invoice request must return exactly one matching selection set.
        guard results.count == 1, let options = results.first, options.invoiceID == invoiceID else {
            throw DocumentError.invalidSelection
        }
        let identifiers = options.receiverSignatures.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw DocumentError.invalidSelection
        }
        return options
    }

    /// Generates, downloads, and persists a PDF for the selected signatures.
    func generate(selection: InvoiceSignatureSelection, language: AppLanguage,
                  isAuthorized: () -> Bool) async throws -> InvoiceDocument {
        let request = InvoiceReportRequest(selections: [selection], language: language)
        let report = try await client.post("reports/invoices", body: request, as: GeneratedReport.self)

        // A revoked session must neither fetch the report URL nor save its contents.
        try rejectInactiveRequest(isAuthorized: isAuthorized)
        let pdf = try await ReportDownloader().download(report.url)
        try rejectInactiveRequest(isAuthorized: isAuthorized)

        // Persist the verified PDF before handing it back to the preview.
        let document = InvoiceDocument(id: UUID(), reportID: report.reportID, selection: selection,
            savedAt: .now, pdf: pdf)
        try await store.saveDocument(document)
        return document
    }

    /// Rejects work that can no longer be published for the current session.
    private func rejectInactiveRequest(isAuthorized: () -> Bool) throws {
        try Task.checkCancellation()
        guard isAuthorized() else {
            throw CancellationError()
        }
    }
}
