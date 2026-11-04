import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import EMSYS

@MainActor
final class InvoicePoolTests: XCTestCase {
    func testEmptyPoolRejectsCreationWithoutSavingDraftOrOutbox() async throws {
        let (store, _) = try await fixture()
        let id = UUID()
        do { _ = try await store.queueInvoiceCreation(draftID: id, expectedRevision: nil, plan: plan()); XCTFail("An empty pool must block creation") }
        catch InvoiceStore.StoreError.invoicePoolEmpty { }
        let draft = try await store.draft(id: id)
        let creation = try await store.invoiceCreation(draftID: id)
        XCTAssertNil(draft); XCTAssertNil(creation)
    }

    func testReservationAndOutboxCommitTogetherAndCannotBeSelectedOrReturnedTwice() async throws {
        let (store, directory) = try await fixture()
        let reservation = try await seed(store)
        let creation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan())
        XCTAssertEqual(creation.plan.reservation, reservation)
        let body = try XCTUnwrap(creation.invoiceRequest)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let invoice = try XCTUnwrap(envelope["invoice"] as? [String: Any])
        XCTAssertEqual(invoice["autoGenerateNumber"] as? Bool, false)
        XCTAssertEqual(invoice["number"] as? String, reservation.number)
        XCTAssertEqual((invoice["reservation"] as? [String: String])?["token"], reservation.allocation.token)
        do { _ = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan()); XCTFail("Number reused") }
        catch InvoiceStore.StoreError.invoicePoolEmpty { }
        let deviceID = try await store.invoicePoolDeviceID()
        do { try await store.stageInvoicePoolAction(.init(action: .return, deviceID: deviceID, items: [reservation])); XCTFail("Used number returned") }
        catch InvoiceStore.StoreError.invoiceReservationChanged { }
        // A server refresh before upload must not resurrect the consumed number.
        try await store.reconcileInvoiceReservations([reservation], lowThreshold: 10)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let count = try await reopened.availableInvoiceReservationCount()
        XCTAssertEqual(count, 0)
        let saved = try await reopened.invoiceCreation(draftID: creation.draftID)
        XCTAssertEqual(saved?.invoiceRequest, body)
    }

    func testReturnQuarantineSurvivesReopenAndOnlyNewAssignmentCanRestoreAvailability() async throws {
        let (store, directory) = try await fixture()
        let reservation = try await seed(store)
        let deviceID = try await store.invoicePoolDeviceID()
        let action = InvoicePoolAction(action: .return, deviceID: deviceID, items: [reservation])
        try await store.stageInvoicePoolAction(action)
        let frozen = try await store.invoicePoolActionPayload(id: action.id)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let reopenedDevice = try await reopened.invoicePoolDeviceID()
        let reopenedPayload = try await reopened.invoicePoolActionPayload(id: action.id)
        XCTAssertEqual(reopenedDevice, deviceID); XCTAssertEqual(frozen, reopenedPayload)
        try await reopened.reconcileInvoiceReservations([reservation], lowThreshold: 10)
        var count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 0)
        try await reopened.acknowledgeInvoicePoolAction(action)
        try await reopened.reconcileInvoiceReservations([reservation], lowThreshold: 10)
        count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 0)
        let reassigned = InvoiceReservation(id: reservation.id, number: reservation.number,
            allocation: .init(employeeId: 12, token: UUID().uuidString.lowercased(), deviceId: deviceID.uuidString.lowercased()))
        try await reopened.reconcileInvoiceReservations([reassigned], lowThreshold: 10)
        count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 1)
        let secondReturn = InvoicePoolAction(action: .return, deviceID: deviceID, items: [reassigned])
        try await reopened.stageInvoicePoolAction(secondReturn)
        try await reopened.acknowledgeInvoicePoolAction(secondReturn)
        // A download from the first assignment may finish after the second return.
        try await reopened.reconcileInvoiceReservations([reservation], lowThreshold: 10)
        count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 0)
        try await reopened.reconcileInvoiceReservations([reassigned], lowThreshold: 10)
        count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 0)
    }

    func testFailedDraftRevisionRollsBackLocalConsumption() async throws {
        let (store, _) = try await fixture()
        _ = try await seed(store)
        do { _ = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: 7, plan: plan()); XCTFail("Missing revision accepted") }
        catch InvoiceStore.StoreError.draftChanged { }
        let count = try await store.availableInvoiceReservationCount(); XCTAssertEqual(count, 1)
    }

    func testWrongDeviceAndTenantCannotUseDownloadedPool() async throws {
        let (store, directory) = try await fixture()
        let reservation = try await seed(store)
        let other = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let count = try await other.availableInvoiceReservationCount(); XCTAssertEqual(count, 0)
        do { try await other.reconcileInvoiceReservations([reservation], lowThreshold: 10); XCTFail("Foreign installation accepted") }
        catch InvoiceStore.StoreError.invoiceReservationChanged { }
    }

    func testReceiptCannotReplaceTheReservedIdentity() async throws {
        let (store, _) = try await fixture()
        _ = try await seed(store)
        let creation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan())
        let foreign = try JSONDecoder().decode(Invoice.self, from: Data(#"{"id":"000000000000000000000099","number":"WRONG"}"#.utf8))
        do { try await store.completeInvoiceCreation(id: creation.id, invoice: foreign); XCTFail("Foreign invoice accepted") }
        catch InvoiceStore.StoreError.invalidCreationReceipt { }
    }

    func testLowPoolStateAndGenerationPermissionAndNativeLayout() async throws {
        let (store, _) = try await fixture()
        _ = try await seed(store)
        let model = InvoicePoolModel(store: store, client: nil, canGenerate: { false }, isAuthorized: { true })
        await model.load()
        XCTAssertEqual(model.available, 1); XCTAssertTrue(model.isLow); XCTAssertFalse(model.canGenerateNumbers)
        await model.generateNumbers()
        let pending = try await store.pendingInvoicePoolActions(); XCTAssertTrue(pending.isEmpty)
        #if os(macOS)
        let hosting = NSHostingView(rootView: InvoicePoolView(model: model).environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/emsys-invoice-pool-apple.png"))
            }
        }
        #endif
    }

    func testMobileGenerationUsesExplicitSelfActionEvenForAdministrators() async throws {
        let (store, _) = try await fixture()
        let model = InvoicePoolModel(store: store, client: nil, canGenerate: { true }, isAuthorized: { true })
        await model.generateNumbers()
        let pending = try await store.pendingInvoicePoolActions()
        let action = try XCTUnwrap(pending.first)
        let bytes = try await store.invoicePoolActionPayload(id: action.id)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "generate-self")
        XCTAssertEqual(body["count"] as? Int, 50)
        XCTAssertNil(body["employeeId"])
    }

    func testDelayedEmptyDownloadCannotRemoveNewerLocalAssignments() async throws {
        let (store, _) = try await fixture()
        let item = try await seed(store)
        let revision = try await store.invoicePoolRevision()
        try await store.reconcileInvoiceReservations([item], lowThreshold: 10, expectedRevision: revision)
        do {
            try await store.reconcileInvoiceReservations([], lowThreshold: 10, expectedRevision: revision)
            XCTFail("An older download replaced a newer pool snapshot")
        } catch InvoiceStore.StoreError.invoiceReservationChanged { }
        let count = try await store.availableInvoiceReservationCount()
        XCTAssertEqual(count, 1)
    }

    private func fixture() async throws -> (InvoiceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company"), directory)
    }
    private func seed(_ store: InvoiceStore) async throws -> InvoiceReservation {
        let deviceID = try await store.invoicePoolDeviceID()
        let item = InvoiceReservation(id: "000000000000000000000003", number: "INV-TEST-1",
            allocation: .init(employeeId: 12, token: UUID().uuidString.lowercased(), deviceId: deviceID.uuidString.lowercased()))
        try await store.reconcileInvoiceReservations([item], lowThreshold: 10)
        return item
    }
    private func plan() throws -> InvoiceCreationPlan {
        let customer = Data(#"{"id":"000000000000000000000001","name":"Sender","customerType":1}"#.utf8)
        var content = InvoiceDraft.Content()
        content.date = try XCTUnwrap(InvoiceDate(apiValue: "2026-11-03"))
        content.senderCustomer = try JSONDecoder().decode(InvoiceCustomer.self, from: customer)
        content.senderWriteSnapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: customer)
        content.senderName = "Sender"
        content.items = [.init(name: "Box", quantity: "1", unitPrice: "20", labelCount: "1")]
        content.policies = []; content.paymentRegion = "NY"; content.payment = InvoiceDraftPayment(mode: .skip)
        return try InvoiceCreationPlan(content: content, branch: .init(id: 1, name: "New York", code: "NY"))
    }
}
