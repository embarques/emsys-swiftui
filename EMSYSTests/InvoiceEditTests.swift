import GRDB
import XCTest
@testable import EMSYS

@MainActor
final class InvoiceEditTests: XCTestCase {
    private let invoiceID = "68f800000000000000000001"
    private let itemID = "68f800000000000000000002"

    func testFullWriteDocumentPreservesUnknownFieldsAndExactNumbers() throws {
        let original = try fixture()
        let changed = try original.invoice.changingItemNames([itemID: "  Large box  "])
        let data = try changed.document.encoded()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((fields["futureInteger"] as? NSNumber)?.stringValue, "9007199254740993")
        XCTAssertEqual(fields["numericText"] as? String, "007")
        XCTAssertEqual(fields["flag"] as? Bool, false)
        XCTAssertTrue(fields["nullable"] is NSNull)
        XCTAssertEqual((fields["cost"] as? NSNumber)?.decimalValue, Decimal(string: "12.34"))
        let details = try XCTUnwrap(fields["invoiceDetails"] as? [[String: Any]])
        XCTAssertEqual(details[0]["name"] as? String, "Large box")
        XCTAssertNil(details[0]["description"], "Free text must clear the portal's catalog reference")
        XCTAssertEqual((details[0]["labels"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(details[0]["unknownItemField"] as? String, "preserved")
        XCTAssertEqual(changed.changes.first?.originalName, "Box")
        XCTAssertEqual(changed.changes.first?.updatedName, "Large box")
        XCTAssertThrowsError(try original.invoice.changingItemNames([itemID: "Box"]))
        XCTAssertThrowsError(try original.invoice.changingItemNames([itemID: "  "]))
        XCTAssertThrowsError(try original.invoice.changingItemNames(["68f800000000000000000099": "Wrong item"]))
    }

    func testOutboxAndLocalProjectionSurviveReopenWithoutRefreshOverwritingWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let original = try fixture()
        try await store.saveEditSnapshot(original)
        let before = try await store.downloadVersion()
        let queued = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "Offline box"])
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.pendingEdits()
        XCTAssertEqual(restored.map(\.id), [queued.id])
        XCTAssertEqual(restored.first?.requestBody, queued.requestBody)
        let local = try await reopened.invoice(id: invoiceID)
        XCTAssertEqual(local?.invoiceDetails?.first?.name, "Offline box")
        try await reopened.saveDownloaded([original.invoice.projection()])
        let retained = try await reopened.invoice(id: invoiceID)
        XCTAssertEqual(retained?.invoiceDetails?.first?.name, "Offline box")
        do {
            _ = try await reopened.queueItemNames(invoiceID: invoiceID, names: [itemID: "Another edit"])
            XCTFail("An attempted operation's body cannot be replaced")
        } catch InvoiceStore.StoreError.editAlreadyPending { }

        let updated = try original.invoice.changingItemNames([itemID: "Offline box"]).document
        let confirmed = InvoiceEditSnapshot(invoice: updated, revision: "v1:" + String(repeating: "b", count: 64))
        try await reopened.completeEdit(editID: queued.id, snapshot: confirmed)
        // Simulates another window finishing a download started before the edit.
        try await store.saveDownloaded([original.invoice.projection()], ifUnchangedSince: before)
        let final = try await store.invoice(id: invoiceID)
        XCTAssertEqual(final?.invoiceDetails?.first?.name, "Offline box")
        let pending = try await reopened.pendingEdits()
        XCTAssertTrue(pending.isEmpty)
        let baseline = try await reopened.editSnapshot(invoiceID: invoiceID)
        XCTAssertEqual(baseline?.revision, confirmed.revision)
    }

    func testProjectionFailureRollsBackTheOutboxInTheSameTransaction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveEditSnapshot(fixture())
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let file = try XCTUnwrap((enumerator.allObjects as? [URL])?.first { $0.lastPathComponent == "invoices.sqlite" })
        let fixtureDatabase = try DatabaseQueue(path: file.path)
        try await fixtureDatabase.write { database in
            try database.execute(sql: """
                CREATE TRIGGER rejectFixtureProjection BEFORE UPDATE ON invoiceSnapshots
                BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END
                """)
        }
        let version = try await store.downloadVersion()
        do {
            _ = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "Must roll back"])
            XCTFail("Expected the projection write to fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let edits = try await store.pendingEdits()
        let unchanged = try await store.invoice(id: invoiceID)
        let finalVersion = try await store.downloadVersion()
        XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(unchanged?.invoiceDetails?.first?.name, "Box")
        XCTAssertEqual(finalVersion, version)
    }

    func testAPIEnvironmentsCannotShareWritableSnapshotsOrEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let development = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company", apiEnvironment: "https://development.example.test/v1")
        try await production.saveEditSnapshot(fixture())
        _ = try await production.queueItemNames(invoiceID: invoiceID, names: [itemID: "Production draft"])
        let otherSnapshot = try await development.editSnapshot(invoiceID: invoiceID)
        let otherEdits = try await development.pendingEdits()
        XCTAssertNil(otherSnapshot)
        XCTAssertTrue(otherEdits.isEmpty)
    }

    func testReviewedNamesRebaseOntoLatestServerFieldsUsingANewIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveEditSnapshot(fixture())
        let queued = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "My box"])
        try await store.requireReview(editID: queued.id, state: .needsReview)
        let latest = try newerFixture()
        try await store.saveEditSnapshot(latest)
        let replacement = try await store.resolveEdit(editID: queued.id, latest: latest, keepLocalNames: true)
        XCTAssertNotEqual(replacement?.id, queued.id)
        XCTAssertEqual(replacement?.expectedRevision, latest.revision)
        let current = try await store.invoice(id: invoiceID)
        XCTAssertEqual(current?.invoiceDetails?.first?.name, "My box")
        XCTAssertEqual(current?.receiver?.name, "Updated receiver")
        XCTAssertEqual(current?.cost, Decimal(20))
        XCTAssertEqual(current?.invoiceDetails?.first?.price, Decimal(10))
        XCTAssertEqual(replacement?.changes.first?.originalName, "Server box")
        let pending = try await store.pendingEdits()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotEqual(pending.first?.requestBody, queued.requestBody)
    }

    func testExplicitServerChoiceResolvesTheConflictWithoutUploadingOldWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveEditSnapshot(fixture())
        let queued = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "My box"])
        try await store.requireReview(editID: queued.id, state: .needsReview)
        let latest = try newerFixture()
        try await store.saveEditSnapshot(latest)
        let replacement = try await store.resolveEdit(editID: queued.id, latest: latest, keepLocalNames: false)
        XCTAssertNil(replacement)
        let active = try await store.activeEdit(invoiceID: invoiceID)
        let projection = try await store.invoice(id: invoiceID)
        XCTAssertNil(active)
        XCTAssertEqual(projection?.invoiceDetails?.first?.name, "Server box")
    }

    func testAnOpenEditorNeverAdoptsANewerRevisionBehindTheUsersBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let original = try fixture()
        try await store.saveEditSnapshot(original)
        let sessionID = UUID()
        let client = try APIClient(baseURL: URL(string: "https://api.example.test/v1")!) { _ in
            APICredentials(sessionID: sessionID, userID: "user", companyID: "company", idToken: "fixture-token")
        }
        let editor = InvoiceItemEditorModel(invoiceID: invoiceID, client: client, store: store, isAuthorized: { true })
        await editor.load()
        editor.setName("My box", itemID: itemID)
        let latest = try newerFixture()
        try await store.saveEditSnapshot(latest)
        await editor.save()
        XCTAssertTrue(editor.didSave)
        XCTAssertEqual(editor.queuedEdit?.expectedRevision, original.revision)
        XCTAssertEqual(editor.queuedEdit?.state, .needsReview)
        let pending = try await store.pendingEdits()
        let baseline = try await store.editSnapshot(invoiceID: invoiceID)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(baseline?.revision, latest.revision)
    }

    func testInvoicePaginationUsesAnIndexWithoutSortingTheEntireCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveEditSnapshot(fixture())
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let file = try XCTUnwrap((enumerator.allObjects as? [URL])?.first { $0.lastPathComponent == "invoices.sqlite" })
        let fixtureDatabase = try DatabaseQueue(path: file.path)
        let queryPlan = try await fixtureDatabase.read { database in
            try Row.fetchAll(database, sql: """
                EXPLAIN QUERY PLAN SELECT payload FROM invoiceSnapshots
                ORDER BY number COLLATE NOCASE DESC, id DESC LIMIT 40 OFFSET 40
                """).map { (row: Row) -> String in row["detail"] }.joined(separator: " ")
        }
        XCTAssertTrue(queryPlan.contains("invoiceSnapshotsByNumberCaseInsensitive"), queryPlan)
        XCTAssertFalse(queryPlan.contains("TEMP B-TREE"), queryPlan)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let invoices = try await reopened.invoices()
        XCTAssertEqual(invoices.map(\.id), [invoiceID])
    }

    private func newerFixture() throws -> InvoiceEditSnapshot {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().invoice.encoded()) as? [String: Any])
        fields["receiver"] = ["name": "Updated receiver"]
        fields["cost"] = 20
        fields["balance"] = 20
        fields["invoiceDetails"] = [["id": itemID, "name": "Server box", "quantity": 2, "labels": 2, "price": 10, "total": 20]]
        let document = try JSONDecoder().decode(InvoiceWriteDocument.self, from: JSONSerialization.data(withJSONObject: fields))
        return InvoiceEditSnapshot(invoice: document, revision: "v1:" + String(repeating: "b", count: 64))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private func fixture() throws -> InvoiceEditSnapshot {
        let data = Data("""
            {"revision":"v1:\(String(repeating: "a", count: 64))","invoice":{
              "id":"\(invoiceID)","number":"TEST-001","cost":12.34,"balance":12.34,
              "futureInteger":9007199254740993,"numericText":"007","flag":false,"nullable":null,
              "invoiceDetails":[{"id":"\(itemID)","name":"Box","description":"42",
                "quantity":2,"labels":2,"price":6.17,"total":12.34,"unknownItemField":"preserved"}]
            }}
            """.utf8)
        return try JSONDecoder().decode(InvoiceEditSnapshot.self, from: data)
    }
}
