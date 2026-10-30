import XCTest
@testable import EMSYS

@MainActor
final class PickupInvoiceAccessTests: XCTestCase {
    func testDowngradedAccessLocksOpenDraftsAndPreservesSavedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "driver", companyID: "company")
        var content = InvoiceDraft.Content()
        content.senderName = "Saved sender"
        let saved = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        var currentAccess: PickupInvoiceAccess? = .company
        let requiredAccess = try XCTUnwrap(currentAccess)
        let list = InvoiceDraftListModel(assignedOnly: requiredAccess.assignedOnly, store: store,
            isAuthorized: { currentAccess?.permits(requiredAccess) == true })
        await list.load()
        let summary = try XCTUnwrap(list.drafts.first)
        let editor = list.editor(draftID: saved.id)
        await editor.load()
        XCTAssertTrue(editor.isAvailable)
        currentAccess = PickupInvoiceAccess(canCreateInvoices: false, canCreateAssignedInvoices: true)
        XCTAssertFalse(list.isAvailable)
        XCTAssertFalse(editor.isAvailable)
        editor.setPartyName("Unauthorized change", role: .sender)
        await editor.save()
        await list.delete(summary)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "driver", companyID: "company")
        let preserved = try await reopened.draft(id: saved.id)
        XCTAssertEqual(preserved?.content.senderName, "Saved sender")
        XCTAssertEqual(preserved?.revision, saved.revision)
        currentAccess = .company
        XCTAssertTrue(editor.isAvailable)
        XCTAssertTrue(list.isAvailable)
    }

    func testAssignedScreenStaysRestrictedAfterUpgradeAndLocksWhenGrantsAreRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "driver", companyID: "company")
        var currentAccess: PickupInvoiceAccess? = .assignedPickup
        let requiredAccess = try XCTUnwrap(currentAccess)
        let list = InvoiceDraftListModel(assignedOnly: requiredAccess.assignedOnly, store: store,
            isAuthorized: { currentAccess?.permits(requiredAccess) == true })
        XCTAssertTrue(list.isAvailable)
        XCTAssertTrue(list.assignedOnly)
        currentAccess = .company
        XCTAssertTrue(list.isAvailable)
        XCTAssertTrue(list.assignedOnly)
        currentAccess = PickupInvoiceAccess(canCreateInvoices: false, canCreateAssignedInvoices: false)
        XCTAssertFalse(list.isAvailable)
    }
}
