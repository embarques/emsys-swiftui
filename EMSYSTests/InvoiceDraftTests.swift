import GRDB
import XCTest
@testable import EMSYS

@MainActor
final class InvoiceDraftTests: XCTestCase {
    func testUnfinishedInputSurvivesReopenWithoutCreatingAnInvoiceOrUpload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var content = InvoiceDraft.Content()
        content.senderName = "Remitente"
        content.items[0].quantity = "1,"
        content.items[0].unitPrice = "12."
        content.items[0].labelCount = ""
        let id = UUID()
        let saved = try await store.saveDraft(id: id, content: content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: id)
        XCTAssertEqual(restored?.content, content)
        XCTAssertEqual(restored?.revision, saved.revision)
        let invoices = try await reopened.invoices()
        let edits = try await reopened.pendingEdits()
        XCTAssertTrue(invoices.isEmpty)
        XCTAssertTrue(edits.isEmpty)
        let summaries = try await reopened.draftSummaries()
        XCTAssertEqual(summaries.first?.senderName, "Remitente")
        XCTAssertEqual(summaries.first?.itemCount, 1)
    }

    func testAStaleWindowPreservesItsFormAndCanExplicitlySaveAnotherDraft() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await store.saveDraft(id: UUID(), content: InvoiceDraft.Content(), expectedRevision: nil)
        let editor = InvoiceDraftEditorModel(draftID: saved.id, store: store, isAuthorized: { true })
        await editor.load()
        editor.content.senderName = "My unsaved sender"
        var otherContent = saved.content
        otherContent.senderName = "Other window sender"
        let otherStore = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        _ = try await otherStore.saveDraft(id: saved.id, content: otherContent, expectedRevision: saved.revision)
        await editor.save()
        XCTAssertTrue(editor.hasConflict)
        XCTAssertFalse(editor.didSave)
        XCTAssertEqual(editor.content.senderName, "My unsaved sender")
        do {
            try await store.deleteDraft(id: saved.id, expectedRevision: saved.revision)
            XCTFail("Stale delete must not remove the other window's saved work")
        } catch InvoiceStore.StoreError.draftChanged { }
        await editor.save(asCopy: true)
        XCTAssertTrue(editor.didSave)
        let summaries = try await store.draftSummaries()
        XCTAssertEqual(Set(summaries.map(\.senderName)), ["My unsaved sender", "Other window sender"])
        let original = try await store.draft(id: saved.id)
        XCTAssertEqual(original?.content, otherContent)
    }

    func testDraftsRemainScopedToUserTenantAndAPIEnvironment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await owner.saveDraft(id: UUID(), content: InvoiceDraft.Content(), expectedRevision: nil)
        for (user, company, environment) in [
            ("other", "company", APIConfiguration.defaultRoot),
            ("user", "other", APIConfiguration.defaultRoot),
            ("user", "company", "https://development.example.test/v1")
        ] {
            let other = try await InvoiceStore.open(directory: directory, userID: user, companyID: company, apiEnvironment: environment)
            let draft = try await other.draft(id: saved.id)
            let summaries = try await other.draftSummaries()
            XCTAssertNil(draft)
            XCTAssertTrue(summaries.isEmpty)
        }
    }

    func testInvalidDraftCannotReplaceSavedContentAndRevisionCannotOverflow() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await store.saveDraft(id: UUID(), content: InvoiceDraft.Content(), expectedRevision: nil)
        var duplicate = saved.content
        duplicate.items.append(duplicate.items[0])
        do {
            _ = try await store.saveDraft(id: saved.id, content: duplicate, expectedRevision: saved.revision)
            XCTFail("Duplicate local item identities must fail without changing saved content")
        } catch InvoiceStore.StoreError.invalidDraft { }
        do {
            _ = try await store.saveDraft(id: saved.id, content: saved.content, expectedRevision: Int64.max)
            XCTFail("Invalid revision must not overflow")
        } catch InvoiceStore.StoreError.invalidDraft { }
        let restored = try await store.draft(id: saved.id)
        XCTAssertEqual(restored?.content, saved.content)
        XCTAssertEqual(restored?.revision, saved.revision)
    }

    func testSessionChangePreventsSavingAndDeletedDraftCannotBeSilentlyRecreated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var authorized = true
        let editor = InvoiceDraftEditorModel(store: store, isAuthorized: { authorized })
        editor.content.senderName = "Unsubmitted"
        authorized = false
        await editor.save()
        XCTAssertFalse(editor.didSave)
        let empty = try await store.draftSummaries()
        XCTAssertTrue(empty.isEmpty)
        let saved = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        try await store.deleteDraft(id: saved.id, expectedRevision: saved.revision)
        let missing = InvoiceDraftEditorModel(draftID: saved.id, store: store, isAuthorized: { true })
        await missing.load()
        XCTAssertFalse(missing.isLoaded)
        XCTAssertFalse(missing.canSave)
        XCTAssertEqual(missing.issue, "drafts.missing")
    }

    func testDraftSummaryPaginationUsesItsIndexWithoutReadingFullForms() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        for index in 1...3 {
            var content = InvoiceDraft.Content()
            content.senderName = String(index)
            _ = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        }
        let first = try await store.draftSummaries(limit: 2)
        let next = try await store.draftSummaries(limit: 2, offset: 2)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(next.count, 1)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(next.map(\.id))))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let file = try XCTUnwrap((enumerator.allObjects as? [URL])?.first { $0.lastPathComponent == "invoices.sqlite" })
        let database = try DatabaseQueue(path: file.path)
        let plan = try await database.read { database in
            try Row.fetchAll(database, sql: """
                EXPLAIN QUERY PLAN SELECT id, revision, savedAt, senderName, receiverName, itemCount
                FROM invoiceDrafts ORDER BY savedAt DESC, id DESC LIMIT 40 OFFSET 40
                """).map { (row: Row) -> String in row["detail"] }.joined(separator: " ")
        }
        XCTAssertTrue(plan.contains("draftsBySaveTime"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
    }

    func testInvoiceCalendarDayIsStableAcrossDeviceTimeZonesAndRejectsInvalidDays() throws {
        let formatter = ISO8601DateFormatter()
        let instant = try XCTUnwrap(formatter.date(from: "2026-10-25T01:00:00Z"))
        var calendar = InvoiceDate.calendar
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santo_Domingo"))
        let day = InvoiceDate(date: instant, calendar: calendar)
        XCTAssertEqual(day.apiValue, "2026-10-24")
        let roundTrip = InvoiceDate(date: try XCTUnwrap(day.pickerDate), calendar: InvoiceDate.calendar)
        XCTAssertEqual(day, roundTrip)
        let invalid = try JSONDecoder().decode(InvoiceDate.self, from: Data(#"{"year":2026,"month":2,"day":30}"#.utf8))
        XCTAssertNil(invalid.pickerDate)
        let leap = try JSONDecoder().decode(InvoiceDate.self, from: Data(#"{"year":2024,"month":2,"day":29}"#.utf8))
        XCTAssertNotNil(leap.pickerDate)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }
}
