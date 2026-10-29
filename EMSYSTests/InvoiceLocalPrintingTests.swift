import XCTest
import PDFKit
#if os(macOS)
import AppKit
#endif
@testable import EMSYS

@MainActor
final class InvoiceLocalPrintingTests: XCTestCase {
    private func fixture(items: Int = 1) throws -> Invoice {
        let item = #"{"id":"68f800000000000000000002","name":"Caja de ropa y comida","quantity":1,"price":10,"total":10}"#
        let json = """
        {"id":"68f800000000000000000001","number":"INV-TEST-001","date":"2026-10-24T00:00:00Z",
        "sender":{"name":"Cliente de prueba","address":{"address1":"Calle Primera","city":"Ciudad","state":"NY","zipcode":"10001","apartment":"2A"}},
        "receiver":{"name":"Destinatario de prueba"},"cost":10,"discount":1,"surcharge":2,"payment":3,"balance":8,"paidStatus":"OPEN",
        "receivedBy":{"type":"route","name":"2026-10-24-RUTA-LARGA-PARA-VERIFICAR-LOS-SALTOS"},
        "invoiceDetails":[\(Array(repeating: item, count: items).joined(separator: ","))]}
        """
        return try JSONDecoder().decode(Invoice.self, from: Data(json.utf8))
    }

    func testSenderSignatureAndLogoRenderTogetherWithoutCoveringAuthorizationText() async throws {
        let signature = try await SignatureDrawing(strokes: [
            [.init(x: 0.1, y: 0.75), .init(x: 0.3, y: 0.15), .init(x: 0.45, y: 0.8), .init(x: 0.65, y: 0.3), .init(x: 0.9, y: 0.5)]
        ]).pngData()
        var company = InvoicePrintCompany(id: "company", name: "Empresa de prueba", logo: "local-fixture")
        company.logoImage = signature
        let bytes = try InvoicePDFRenderer(invoice: fixture(items: 100), company: company, language: "es-DO",
            printedBy: "Fixture", senderSignaturePNG: signature).render()
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
            let authorization = try XCTUnwrap(pdf.findString("Authorizado por", withOptions: []).first { $0.pages.contains(page) }?.bounds(for: page))
            let terms = try XCTUnwrap(pdf.findString("Al autorizar este servicio", withOptions: []).first { $0.pages.contains(page) }?.bounds(for: page))
            XCTAssertGreaterThan(terms.minY, 110, "Terms must end above the reserved signature area")
            XCTAssertLessThan(authorization.maxY, 65)
        }
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory
        try bytes.write(to: directory.appending(path: "emsys-signed-invoice-fixture.pdf"))
        let image = try XCTUnwrap(pdf.page(at: 0)).thumbnail(of: CGSize(width: 1224, height: 1584), for: .mediaBox)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "emsys-signed-invoice-fixture.png"))
        #endif
    }

    func testGeneratesLetterPDFLocallyAndPreservesFinancialContent() throws {
        let invoice = try fixture()
        let company = InvoicePrintCompany(id: "company", name: "Empresa de prueba")
        let bytes = try InvoicePDFRenderer(invoice: invoice, company: company, language: "en", printedBy: "test@example.test").render()
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
        let text = try XCTUnwrap(pdf.string)
        for expected in ["INV-TEST-001", "10/24/2026", "$10.00", "$1.00", "$2.00", "$3.00", "$8.00", "Caja de ropa", "2A", "By authorizing this service", "Pagina 1/1"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("Al autorizar"))
        #if os(macOS)
        try bytes.write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-native-invoice-fixture.pdf"))
        #endif
    }

    func testMultiPageInvoicesRepeatIdentityAndKeepLocalizedTermsAboveFooter() throws {
        let bytes = try InvoicePDFRenderer(invoice: fixture(items: 100), company: .init(id: "company", name: "Empresa de prueba"), language: "es-DO", printedBy: "Test").render()
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let text = try XCTUnwrap(page.string)
            XCTAssertTrue(text.contains("INV-TEST-001"))
            XCTAssertTrue(text.contains("Al autorizar este servicio"))
            XCTAssertTrue(text.contains("Pagina \(index + 1)/\(pdf.pageCount)"))
            let terms = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))?.string)
            XCTAssertFalse(terms.contains("By authorizing"))
        }
    }

    func testOfflineGenerationPersistsAndScopesCompanyAndDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let invoice = try fixture()
        try await store.saveDownloaded([invoice])
        try await store.savePrintCompany(.init(id: "company", name: "Empresa de prueba"))
        // Reopen the durable cache; generation has no API client or downloader.
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let generated = try await InvoiceLocalPrinting.generate(invoiceID: invoice.id, store: reopened, language: "en", printedBy: "Test")
        let restored = try await reopened.latestDocument(invoiceID: invoice.id)
        XCTAssertEqual(generated.pdf, restored?.pdf)
        let other = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let absent = try await other.printCompany()
        XCTAssertNil(absent)
        let missing = try await other.latestDocument(invoiceID: invoice.id)
        XCTAssertNil(missing)
    }

    func testMissingPrintDataDoesNotInventInvoiceOrCompanyContent() throws {
        var invoice = try fixture()
        invoice = Invoice(id: invoice.id, number: nil, date: invoice.date, sender: nil, receiver: nil, cost: nil, payment: nil, balance: nil, invoiceDetails: nil)
        XCTAssertThrowsError(try InvoicePDFRenderer(invoice: invoice, company: .init(id: "company", name: "Test"), language: "en", printedBy: "Test").render())
        let company = InvoicePrintCompany(id: "company", name: "Test", logo: "https://example.test/logo.png")
        XCTAssertThrowsError(try InvoicePDFRenderer(invoice: fixture(), company: company, language: "en", printedBy: "Test").render())
    }

    func testPreparationSurvivesCancellationOfThePresentingView() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let invoice = try fixture()
        try await store.saveDownloaded([invoice])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrintCompanyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://api.example.test/v1")), session: session) { _ in
            APICredentials(sessionID: identity, userID: "user", companyID: "company", idToken: "fixture")
        }
        let model = InvoiceListModel(client: client, store: store)
        let presenter = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            model.preparePrinting()
        }
        await presenter.value
        let generated = try await model.localPrintDocument(for: invoice, language: "en", printedBy: "Test")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: generated.pdf)?.string).contains("Empresa sincronizada"))
    }

    func testDirectoryPrintDoesNotWaitForRefreshWhenCompanyIsCached() async throws {
        try await verifyCachedPrintDoesNotWaitForRefresh(fromDetail: false)
    }

    func testDetailPrintDoesNotWaitForRefreshWhenCompanyIsCached() async throws {
        try await verifyCachedPrintDoesNotWaitForRefresh(fromDetail: true)
    }

    private func verifyCachedPrintDoesNotWaitForRefresh(fromDetail: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let invoice = try fixture()
        try await store.saveDownloaded([invoice])
        try await store.savePrintCompany(.init(id: "company", name: "Empresa guardada"))

        let refreshStarted = expectation(description: "Company refresh is waiting for credentials")
        let printed = expectation(description: "Cached invoice prints before refresh finishes")
        var finishRefresh: CheckedContinuation<Void, Never>?
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://api.example.test/v1"))) { _ in
            await withCheckedContinuation { continuation in
                finishRefresh = continuation
                refreshStarted.fulfill()
            }
            throw URLError(.notConnectedToInternet)
        }
        let directoryModel = InvoiceListModel(client: client, store: store)
        let detailModel = InvoiceDetailModel(invoice: invoice, client: client, store: store)
        let detailPreparation: Task<Void, Never>?
        if fromDetail {
            detailPreparation = Task { await detailModel.preparePrinting() }
        } else {
            detailPreparation = nil
            directoryModel.preparePrinting()
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let printTask = Task {
            let document: InvoiceDocument
            if fromDetail {
                document = try await detailModel.localPrintDocument(language: "en", printedBy: "Test")
            } else {
                document = try await directoryModel.localPrintDocument(for: invoice, language: "en", printedBy: "Test")
            }
            printed.fulfill()
            return document
        }
        await fulfillment(of: [printed], timeout: 3)
        // Release the suspended refresh even when the expectation fails so the
        // regression reports a failure rather than hanging the test process.
        finishRefresh?.resume()
        let document = try await printTask.value
        await detailPreparation?.value
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: document.pdf)?.string).contains("Empresa guardada"))
        let saved = try await store.latestDocument(invoiceID: invoice.id)
        XCTAssertEqual(saved?.pdf, document.pdf)
        let company = try await store.printCompany()
        XCTAssertEqual(company?.name, "Empresa guardada")
    }

    func testOfflinePrintUsesPendingItemChangesWithoutUploading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let invoice = try fixture()
        let document = try JSONDecoder().decode(InvoiceWriteDocument.self, from: JSONEncoder().encode(invoice))
        try await store.saveEditSnapshot(.init(invoice: document, revision: "v1:" + String(repeating: "a", count: 64)))
        try await store.savePrintCompany(.init(id: "company", name: "Empresa de prueba"))
        try await store.queueItemNames(invoiceID: invoice.id, names: ["68f800000000000000000002": "Caja modificada sin conexión"])
        let generated = try await InvoiceLocalPrinting.generate(invoiceID: invoice.id, store: store, language: "es-DO", printedBy: "Test")
        let text = try XCTUnwrap(PDFDocument(data: generated.pdf)?.string)
        XCTAssertTrue(text.contains("Caja modificada sin conexión"))
        XCTAssertFalse(text.contains("Caja de ropa y comida"))
        let edit = try await store.activeEdit(invoiceID: invoice.id)
        XCTAssertNotNil(edit)
    }

    func testAuthorizationPreventsStartingLocalPrint() async {
        let printer = InvoicePreviewModel()
        var called = false
        printer.generate(isAuthorized: { false }) {
            called = true
            throw DocumentError.invalidSelection
        }
        await Task.yield()
        XCTAssertFalse(called)
        XCTAssertNil(printer.document)
    }
}

private final class PrintCompanyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/v1/companies/current",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"message":"fixture","data":{"id":"company","name":"Empresa sincronizada"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
