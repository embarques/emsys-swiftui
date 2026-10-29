import PDFKit
import XCTest
@testable import EMSYS

@MainActor
final class InvoicePreviewTests: XCTestCase {
    func testGenerationPresentsTheExactSavedPDFForReview() async throws {
        let document = try fixture()
        let preview = InvoicePreviewModel()
        let task = preview.generate(isAuthorized: { true }) { document }
        await task?.value
        XCTAssertEqual(preview.document?.id, document.id)
        XCTAssertEqual(preview.document?.pdf, document.pdf)
        XCTAssertTrue(preview.isAvailable)
        XCTAssertFalse(preview.isGenerating)
        XCTAssertFalse(preview.failed)
        preview.cancel()
        XCTAssertNil(preview.document)
        XCTAssertFalse(preview.isAvailable)
    }

    func testRevokedAuthorizationCannotPublishFinishedGeneration() async throws {
        let document = try fixture()
        let preview = InvoicePreviewModel()
        var authorized = true
        let started = expectation(description: "Generation started")
        var finish: CheckedContinuation<InvoiceDocument, Never>?
        let task = preview.generate(isAuthorized: { authorized }) {
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        authorized = false
        finish?.resume(returning: document)
        await task?.value
        XCTAssertNil(preview.document)
        XCTAssertFalse(preview.failed)
        XCTAssertFalse(preview.isAvailable)
    }

    func testCancellationPreventsOldWorkFromReplacingANewerPreview() async throws {
        let oldDocument = try fixture()
        let newDocument = try fixture()
        let preview = InvoicePreviewModel()
        let started = expectation(description: "Old generation is suspended")
        var finish: CheckedContinuation<InvoiceDocument, Never>?
        let oldTask = preview.generate(isAuthorized: { true }) {
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        var duplicated = false
        let duplicate = preview.generate(isAuthorized: { true }) {
            duplicated = true
            return oldDocument
        }
        XCTAssertNil(duplicate)
        XCTAssertFalse(duplicated)
        preview.cancel()
        let newTask = preview.generate(isAuthorized: { true }) { newDocument }
        await newTask?.value
        finish?.resume(returning: oldDocument)
        await oldTask?.value
        XCTAssertEqual(preview.document?.id, newDocument.id)
        XCTAssertFalse(preview.isGenerating)
        XCTAssertFalse(preview.failed)
    }

    func testGenerationFailureCanBeRetriedWithoutShowingAnOldDocument() async throws {
        let preview = InvoicePreviewModel()
        let failure = preview.generate(isAuthorized: { true }) { throw DocumentError.invalidPDF }
        await failure?.value
        XCTAssertTrue(preview.failed)
        XCTAssertNil(preview.document)
        let document = try fixture()
        let retry = preview.generate(isAuthorized: { true }) { document }
        XCTAssertFalse(preview.failed)
        await retry?.value
        XCTAssertEqual(preview.document?.pdf, document.pdf)
        XCTAssertFalse(preview.failed)
    }

    private func fixture() throws -> InvoiceDocument {
        let json = Data(#"{"id":"68f800000000000000000001","number":"INV-PREVIEW-TEST","date":"2026-10-25","cost":10,"balance":10,"invoiceDetails":[]}"#.utf8)
        let invoice = try JSONDecoder().decode(Invoice.self, from: json)
        let pdf = try InvoicePDFRenderer(invoice: invoice, company: .init(id: "company", name: "Test Company"), language: "en", printedBy: "Test").render()
        try InvoiceDocument.validate(pdf)
        return InvoiceDocument(id: UUID(), reportID: "test-preview", selection: .init(invoiceID: invoice.id, includeSender: false, receiverSignatureID: nil), savedAt: .now, pdf: pdf)
    }
}
