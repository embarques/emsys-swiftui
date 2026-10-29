import XCTest
@testable import EMSYS

@MainActor
final class InvoiceReportRequestTests: XCTestCase {
    func testRequestUsesExplicitSelectionsAndCurrentReportContract() throws {
        let selection = InvoiceSignatureSelection(
            invoiceID: "68f800000000000000000001",
            includeSender: true, receiverSignatureID: nil
        )
        let request = InvoiceReportRequest(selections: [selection], language: .dominicanSpanish)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["lookup_field"] as? String, "id")
        XCTAssertEqual(json["type"] as? String, "invoice")
        XCTAssertEqual(json["collection"] as? String, "invoices")
        XCTAssertEqual(json["language"] as? String, "es")
        XCTAssertEqual(json["values"] as? [String], [selection.invoiceID])
        let choices = try XCTUnwrap(json["signatureSelections"] as? [[String: Any]])
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0]["includeSender"] as? Bool, true)
        XCTAssertNil(choices[0]["receiverSignatureId"])
        XCTAssertEqual(InvoiceReportRequest(selections: [selection], language: .english).language, "en")
    }
}
