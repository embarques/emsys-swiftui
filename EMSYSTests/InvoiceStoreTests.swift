import XCTest
@testable import EMSYS

@MainActor
final class InvoiceStoreTests: XCTestCase {
    func testDownloadedInvoiceSurvivesReopeningWithoutNetwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let invoice = try fixture()
        try await store.saveDownloaded([invoice])

        let reopened = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let restored = try await reopened.invoice(id: invoice.id)
        XCTAssertEqual(restored, invoice)
        XCTAssertEqual(restored?.balance, Decimal(string: "12.34"))
    }

    func testOtherUsersAndTenantsCannotReadStoredInvoices() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        try await owner.saveDownloaded([fixture()])
        for (userID, companyID) in [("user-b", "company-a"), ("user-a", "company-b")] {
            let other = try await InvoiceStore.open(directory: directory, userID: userID, companyID: companyID)
            let invoices = try await other.invoices()
            XCTAssertTrue(invoices.isEmpty)
        }
    }

    func testInvalidMemberRejectsWholePage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        do {
            try await store.saveDownloaded([fixture(), fixture(id: "invalid")])
            XCTFail("Invalid record should reject the whole page")
        } catch {
            XCTAssertTrue(error is InvoiceStore.StoreError)
        }
        let invoices = try await store.invoices()
        XCTAssertTrue(invoices.isEmpty)
    }

    func testDownloadingAgainUpdatesInsteadOfDuplicatingAndDoesNotDeleteOtherPages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let first = try fixture()
        let second = try fixture(id: "68f800000000000000000002", number: "SECOND")
        try await store.saveDownloaded([first, second])
        let changed = try fixture(number: "UPDATED")
        try await store.saveDownloaded([changed])
        let invoices = try await store.invoices()
        XCTAssertEqual(invoices.count, 2)
        XCTAssertEqual(invoices.first { $0.id == first.id }?.number, "UPDATED")
        XCTAssertEqual(invoices.first { $0.id == second.id }, second)
    }

    func testCachedPagesPreserveServerOrderAndAnEmptyPageDoesNotDeleteInvoices() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let first = try fixture()
        let second = try fixture(id: "68f800000000000000000002", number: "SECOND")
        try await store.saveDownloaded([second, first], page: 1)
        let cached = try await store.page(1)
        XCTAssertEqual(cached, [second, first])
        try await store.saveDownloaded([], page: 1)
        let empty = try await store.page(1)
        let stillStored = try await store.invoice(id: first.id)
        XCTAssertEqual(empty, [])
        XCTAssertEqual(stillStored, first)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "EMSYS.Tests.\(UUID().uuidString)")
    }

    func testListRefreshDoesNotEraseDownloadedDetailsAndDetailCanClearItems() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let detail = try JSONDecoder().decode(Invoice.self, from: Data(#"{"id":"68f800000000000000000001","number":"DETAIL","invoiceDetails":[{"id":"68f800000000000000000002","name":"Box","quantity":2}]}"#.utf8))
        try await store.saveDownloaded([detail])
        let summary = try fixture(number: "NEW-SUMMARY")
        try await store.saveDownloaded([summary], page: 1)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user-a", companyID: "company-a")
        let cachedDetail = try await reopened.invoice(id: detail.id)
        let cachedPage = try await reopened.page(1)
        XCTAssertEqual(cachedDetail, detail)
        XCTAssertEqual(cachedPage, [summary])

        // A genuine detail response is authoritative, including removed items.
        let emptyDetail = try JSONDecoder().decode(Invoice.self, from: Data(#"{"id":"68f800000000000000000001","invoiceDetails":[]}"#.utf8))
        try await reopened.saveDownloaded([emptyDetail])
        let cleared = try await reopened.invoice(id: detail.id)
        XCTAssertEqual(cleared?.invoiceDetails, [])
    }

    private func fixture(
        id: String = "68f800000000000000000001",
        number: String = "TEST-001"
    ) throws -> Invoice {
        let payload: [String: Any] = [
            "id": id, "number": number, "balance": 12.34,
            "sender": ["name": "Test Sender"], "receiver": ["name": "Test Receiver"]
        ]
        return try JSONDecoder().decode(Invoice.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
