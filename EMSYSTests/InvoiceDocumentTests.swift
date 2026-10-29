import CoreGraphics
import XCTest
@testable import EMSYS

@MainActor
final class InvoiceDocumentTests: XCTestCase {
    func testDocumentPersistsAtomicallyAndStaysInItsUserTenantPartition() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let document = InvoiceDocument(
            id: UUID(), reportID: "report-test",
            selection: .init(invoiceID: "68f800000000000000000001", includeSender: true, receiverSignatureID: "legacy"),
            savedAt: .now, pdf: try fixturePDF()
        )
        try await store.saveDocument(document)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.latestDocument(invoiceID: document.selection.invoiceID)
        XCTAssertEqual(restored?.id, document.id)
        XCTAssertEqual(restored?.pdf, document.pdf)
        XCTAssertEqual(restored?.selection, document.selection)
        let other = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other-company")
        let absent = try await other.latestDocument(invoiceID: document.selection.invoiceID)
        XCTAssertNil(absent)
        let invalid = InvoiceDocument(id: UUID(), reportID: "bad", selection: document.selection,
            savedAt: .now.addingTimeInterval(1), pdf: Data("not a PDF".utf8))
        do {
            try await store.saveDocument(invalid)
            XCTFail("Invalid document must not replace the valid local copy")
        } catch DocumentError.invalidPDF { }
        let retained = try await reopened.latestDocument(invoiceID: document.selection.invoiceID)
        XCTAssertEqual(retained?.id, document.id)
    }

    func testDownloaderUsesNoAPICredentialsAndValidatesResponse() async throws {
        let downloader = ReportDownloader(protocolClasses: [PDFStubProtocol.self])
        PDFStubProtocol.payload = try fixturePDF()
        PDFStubProtocol.status = 200
        PDFStubProtocol.contentType = "application/pdf"
        PDFStubProtocol.length = nil
        let data = try await downloader.download(URL(string: "https://reports.example.test/document?token=test")!)
        XCTAssertEqual(data, PDFStubProtocol.payload)
        let request = try XCTUnwrap(PDFStubProtocol.request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Company-ID"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        for status in [302, 403, 404, 500] {
            PDFStubProtocol.status = status
            do {
                _ = try await downloader.download(request.url!)
                XCTFail("Unexpected status must not produce a saved PDF")
            } catch DocumentError.invalidResponse { }
        }
        PDFStubProtocol.status = 200
        PDFStubProtocol.contentType = "text/html"
        do {
            _ = try await downloader.download(request.url!)
            XCTFail("Reject non-PDF response")
        } catch DocumentError.invalidResponse { }
        PDFStubProtocol.contentType = "application/pdf"
        PDFStubProtocol.length = InvoiceDocument.maximumBytes + 1
        do {
            _ = try await downloader.download(request.url!)
            XCTFail("Reject oversized download before consuming body")
        } catch DocumentError.tooLarge { }
        PDFStubProtocol.length = nil
        PDFStubProtocol.payload = Data(repeating: 0, count: InvoiceDocument.maximumBytes + 1)
        do {
            _ = try await downloader.download(request.url!)
            XCTFail("A response without Content-Length must still be bounded")
        } catch DocumentError.tooLarge { }
        PDFStubProtocol.payload = Data()
    }

    func testDownloaderRejectsUnsafeLocationsBeforeSendingARequest() async throws {
        let downloader = ReportDownloader(protocolClasses: [PDFStubProtocol.self])
        PDFStubProtocol.request = nil
        for location in ["http://reports.example.test/test", "file:///tmp/test.pdf",
                         "https://user:password@reports.example.test/test", "https://reports.example.test/test#fragment"] {
            do {
                _ = try await downloader.download(try XCTUnwrap(URL(string: location)))
                XCTFail("Unsafe location must not be fetched")
            } catch DocumentError.invalidURL { }
        }
        XCTAssertNil(PDFStubProtocol.request)
    }

    private func fixturePDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

private final class PDFStubProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var contentType = "application/pdf"
    nonisolated(unsafe) static var length: Int?
    nonisolated(unsafe) static var request: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        var headers = ["Content-Type": Self.contentType]
        if let length = Self.length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
