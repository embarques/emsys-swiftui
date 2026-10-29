import CoreGraphics
import PDFKit
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import EMSYS

@MainActor
final class InvoicePrintingTests: XCTestCase {
    #if os(macOS)
    func testPrintOperationKeepsAPIPaperSizeAndDoesNotInheritScaling() throws {
        let pdf = try fixturePDF()
        let base = try XCTUnwrap(NSPrintInfo.shared.copy() as? NSPrintInfo)
        base.paperSize = NSSize(width: 595, height: 842)
        base.scalingFactor = 0.5
        let originalPaperSize = base.paperSize
        let operation = try XCTUnwrap(InvoicePrintConfiguration.operation(pdf: pdf, base: base))
        XCTAssertEqual(operation.printInfo.paperSize.width, 612, accuracy: 0.01)
        XCTAssertEqual(operation.printInfo.paperSize.height, 792, accuracy: 0.01)
        XCTAssertEqual(operation.printInfo.scalingFactor, 1)
        XCTAssertEqual(base.scalingFactor, 0.5, "Do not change another print job's settings")
        XCTAssertEqual(base.paperSize, originalPaperSize)
        XCTAssertNil(InvoicePrintConfiguration.operation(pdf: Data("invalid".utf8)))
    }
    #else
    func testAirPrintReceivesTheExactSavedAPIBytes() throws {
        let pdf = try fixturePDF()
        let controller = UIPrintInteractionController.shared
        InvoicePrintConfiguration.configure(controller, pdf: pdf)
        XCTAssertEqual(submittedPDF(controller), pdf)
        XCTAssertNil(controller.printFormatter)
        XCTAssertNil(controller.printPageRenderer)
        XCTAssertEqual(controller.printInfo?.orientation, .portrait)
        XCTAssertEqual(controller.printInfo?.duplex, UIPrintInfo.Duplex.none)
        // Reusing the system controller must replace the preceding invoice.
        let second = try fixturePDF(pageCount: 1)
        InvoicePrintConfiguration.configure(controller, pdf: second)
        XCTAssertEqual(submittedPDF(controller), second)
    }
    // UIKit may expose a single submitted item through printingItems after
    // normalizing its input. Check the actual bytes in either representation.
    private func submittedPDF(_ controller: UIPrintInteractionController) -> Data? {
        if let data = controller.printingItem as? Data { return data }
        guard let items = controller.printingItems, items.count == 1 else { return nil }
        return items.first as? Data
    }
    #endif

    func testSavedLetterInvoiceRetainsItsBytesAndPageGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try fixturePDF()
        let store = try await InvoiceStore.open(directory: directory, userID: "print-user", companyID: "print-company")
        let document = InvoiceDocument(id: UUID(), reportID: "api-report",
            selection: .init(invoiceID: "68f800000000000000000001", includeSender: true, receiverSignatureID: nil),
            savedAt: .now, pdf: pdf)
        try await store.saveDocument(document)
        let restored = try await store.latestDocument(invoiceID: "68f800000000000000000001")
        let saved = try XCTUnwrap(restored)
        XCTAssertEqual(saved.pdf, pdf)
        let decoded = try XCTUnwrap(PDFDocument(data: saved.pdf))
        XCTAssertEqual(decoded.pageCount, 2)
        for index in 0..<decoded.pageCount {
            let page = try XCTUnwrap(decoded.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
            XCTAssertEqual(page.rotation, 0)
        }
    }

    private func fixturePDF(pageCount: Int = 2) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 40 + index, width: 552, height: 1))
            context.fill(CGRect(x: 30, y: 700, width: 552, height: 30))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
