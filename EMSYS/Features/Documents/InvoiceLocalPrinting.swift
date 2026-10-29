import Foundation
import OSLog

/// Networking belongs to preparation, never to the Print action. Cached tenant
/// settings remain available through offline sessions and application restarts.
nonisolated enum InvoiceLocalPrinting {
    static func logPreparationFailure(_ error: Error) {
        let code = (error as NSError).code
        Logger(subsystem: "com.embarqueros.emsys", category: "InvoicePrinting").error(
            "Print preparation failed: type=\(String(reflecting: type(of: error)), privacy: .public), code=\(code, privacy: .public), cancelled=\(Task.isCancelled, privacy: .public)"
        )
    }

    static func prepare(client: APIClient, store: InvoiceStore) async throws {
        var company = try await client.get("companies/current", as: InvoicePrintCompany.self)
        if let logo = company.logo, !logo.isEmpty {
            if let saved = try await store.printCompany(), saved.logo == logo, let image = saved.logoImage {
                company.logoImage = image
            } else if logo.hasPrefix("data:image/"), let encoded = logo.split(separator: ",", maxSplits: 1).last,
                      let image = Data(base64Encoded: String(encoded)), image.count <= 2 * 1024 * 1024 {
                company.logoImage = image
            } else {
                guard let url = URL(string: logo), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil else { throw DocumentError.invalidURL }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https", response.expectedContentLength <= 2 * 1024 * 1024 else {
                    throw DocumentError.invalidResponse
                }
                var image = Data()
                for try await byte in bytes {
                    guard image.count < 2 * 1024 * 1024 else { throw DocumentError.tooLarge }
                    image.append(byte)
                }
                let downloadedImage = image
                try await Task.detached(priority: .utility) {
                    var validation = InvoicePDFCanvas()
                    try validation.addImage(downloadedImage)
                }.value
                company.logoImage = downloadedImage
            }
        }
        try Task.checkCancellation()
        try await store.savePrintCompany(company)
    }

    static func generate(invoiceID: String, store: InvoiceStore, language: String, printedBy: String) async throws -> InvoiceDocument {
        guard let invoice = try await store.invoice(id: invoiceID) else { throw InvoicePDFRenderer.RenderError.missingInvoice }
        guard let company = try await store.printCompany() else { throw InvoicePDFRenderer.RenderError.missingCompany }
        let signaturePNG = try await store.localSenderSignature(invoiceID: invoiceID)
        let document = try await Task.detached(priority: .userInitiated) {
            let pdf = try InvoicePDFRenderer(invoice: invoice, company: company, language: language, printedBy: printedBy,
                                             senderSignaturePNG: signaturePNG).render()
            return InvoiceDocument(id: UUID(), reportID: "local-invoice-v1-" + UUID().uuidString,
                selection: InvoiceSignatureSelection(invoiceID: invoiceID, includeSender: signaturePNG != nil, receiverSignatureID: nil),
                savedAt: .now, pdf: pdf)
        }.value
        try Task.checkCancellation()
        try await store.saveDocument(document)
        return document
    }
}
