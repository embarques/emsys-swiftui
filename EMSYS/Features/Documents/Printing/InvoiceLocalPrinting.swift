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

    static func generatePending(_ operation: PendingInvoiceCreation, store: InvoiceStore,
                                language: String, printedBy: String) async throws -> InvoiceDocument {
        let company = try await store.printCompany() ?? InvoicePrintCompany(id: "", name: "EMSYS")
        let document = try await Task.detached(priority: .userInitiated) {
            let content = operation.plan.content
            let amounts = try InvoiceDraftAmounts(items: content.items)
            let discount = content.payment?.totals(subtotal: amounts.subtotal)?.discount ?? 0
            let items = content.items.map {
                Invoice.Item(id: $0.id.uuidString, name: $0.name, description: nil,
                    quantity: Decimal(string: $0.quantity.trimmingCharacters(in: .whitespacesAndNewlines)),
                    price: Decimal(string: $0.unitPrice.trimmingCharacters(in: .whitespacesAndNewlines)),
                    total: amounts.lineTotals[$0.id].map { Decimal($0) })
            }
            func party(_ snapshot: InvoiceCustomerWriteSnapshot?, addressID: String?, name: String) throws -> Invoice.Party {
                let party = try snapshot?.party(addressID: addressID)
                let address = party?.address.map {
                    Invoice.Address(address1: $0.address1, address2: $0.address2, city: $0.city, state: $0.state,
                                    zipcode: $0.zipcode, isPrimary: $0.isPrimary, apartment: $0.apartment)
                }
                return Invoice.Party(name: party?.name ?? name, id: party?.id, phones: party?.phones.map {
                    Invoice.Phone(number: $0.number, displayNumber: nil, isPrimary: $0.isPrimary)
                }, address: address)
            }
            let id = operation.plan.reservation?.id ?? operation.id.uuidString
            let number = operation.plan.reservation?.number
            let receipt = operation.paymentReceipt
            let noPayment = !operation.plan.requiresJournal
            let payment = receipt?.invoice.payment ?? (noPayment ? 0 : nil)
            let balance = receipt?.invoice.balance ?? (noPayment ? amounts.subtotal - discount : nil)
            var invoice = Invoice(id: id, number: number, date: content.date.apiValue,
                sender: try party(content.senderWriteSnapshot, addressID: content.senderAddressID, name: content.senderName),
                receiver: try party(content.receiverWriteSnapshot, addressID: content.receiverAddressID, name: content.receiverName),
                cost: Decimal(amounts.subtotal), payment: payment.map { Decimal($0) },
                balance: balance.map { Decimal($0) }, invoiceDetails: items)
            invoice.discount = Decimal(discount)
            invoice.container = content.container.map { .init(name: $0.name, id: UInt16(exactly: $0.id), containerNumber: $0.containerNumber) }
            if let route = content.pickupRoute {
                invoice.receivedBy = .init(type: "route", name: route.displayName)
            } else if let employee = content.pickupEmployee {
                invoice.receivedBy = .init(type: "employee", name: employee.name)
            }
            if balance == nil { invoice.paidStatus = "-" }
            let signature = content.confirmation?.skipSignature == true ? nil : content.senderSignature?.pngData
            let pdf = try InvoicePDFRenderer(invoice: invoice, company: company, language: language,
                printedBy: printedBy, senderSignaturePNG: signature, isPendingSync: true).render()
            return InvoiceDocument(id: UUID(), reportID: "local-pending-invoice-" + UUID().uuidString,
                selection: .init(invoiceID: id, includeSender: signature != nil, receiverSignatureID: nil),
                savedAt: .now, pdf: pdf)
        }.value
        try Task.checkCancellation()
        return document
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
