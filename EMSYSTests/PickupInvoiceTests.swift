import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class PickupInvoiceTests: XCTestCase {
    func testPrefillRequiresRecipientChoiceAndDoesNotPriceInstructions() throws {
        let pickup = try fixture()
        XCTAssertThrowsError(try PickupInvoicePrefill.content(from: pickup))
        let content = try PickupInvoicePrefill.content(from: pickup, receiverID: "000000000000000000000003")
        XCTAssertEqual(content.pickup?.id, 42)
        XCTAssertEqual(content.senderName, "Sender")
        XCTAssertEqual(content.receiverName, "Second recipient")
        XCTAssertEqual(content.items, [InvoiceDraft.Item(id: content.items[0].id)])
        XCTAssertNil(content.container)
        XCTAssertNil(content.pickupSource)
        XCTAssertThrowsError(try PickupInvoicePrefill.content(from: pickup, receiverID: "000000000000000000000099"))
        XCTAssertEqual(PickupInvoicePrefill.receivers(in: pickup).count, 2)
    }

    func testLinkedDraftCanBeSavedImmediatelyAndReopenedOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let content = try PickupInvoicePrefill.content(from: fixture(), receiverID: "000000000000000000000002")
        let editor = InvoiceDraftEditorModel(initialContent: content, store: store, isAuthorized: { true })
        XCTAssertTrue(editor.canSave)
        await editor.save()
        let summaries = try await store.draftSummaries()
        let id = try XCTUnwrap(summaries.first?.id)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await reopened.draft(id: id)
        XCTAssertEqual(saved?.content.pickup?.id, 42)
        XCTAssertEqual(saved?.content.receiverName, "First recipient")
        XCTAssertEqual(saved?.content, content)
        var invalid = content
        invalid.pickup = InvoicePickupReference(id: 0)
        do {
            _ = try await reopened.saveDraft(id: UUID(), content: invalid, expectedRevision: nil)
            XCTFail("An invalid pickup ID must not enter SQLite")
        } catch InvoiceStore.StoreError.invalidDraft { }
    }

    func testOfflineHydrationUsesCurrentCustomerNamesAndFirstAddressesForBothParties() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let initial = try PickupInvoicePrefill.content(from: fixture(), receiverID: "000000000000000000000002")
        for (id, role, name) in [("000000000000000000000001", 1, "Updated sender"),
                                 ("000000000000000000000002", 2, "Updated recipient")] {
            let body: [String: Any] = ["id": id, "customerType": role, "name": name,
                "addresses": [["id": "000000000000000000000010", "address1": "First address"],
                              ["id": "000000000000000000000011", "address1": "Second address"]]]
            let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self,
                from: JSONSerialization.data(withJSONObject: body))
            try await store.saveCustomerWriteSnapshot(snapshot)
        }
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1"))) { _ in
            XCTFail("Offline hydration must not request credentials")
            throw APIClientError.missingCredentials
        }
        let editor = InvoiceDraftEditorModel(initialContent: initial, store: store, client: client,
            canViewCustomers: { true }, isAuthorized: { true })
        await editor.loadCustomerDetails(online: false)
        XCTAssertNil(editor.customerDetailsIssue)
        XCTAssertEqual(editor.content.senderName, "Updated sender")
        XCTAssertEqual(editor.content.receiverName, "Updated recipient")
        XCTAssertEqual(editor.content.senderAddressID, "000000000000000000000010")
        XCTAssertEqual(editor.content.receiverAddressID, "000000000000000000000010")
        XCTAssertNotNil(editor.content.senderWriteSnapshot)
        XCTAssertNotNil(editor.content.receiverWriteSnapshot)
        editor.content.senderAddressID = "000000000000000000000011"
        await editor.loadCustomerDetails(online: false)
        XCTAssertEqual(editor.content.senderAddressID, "000000000000000000000011")
    }

    func testOldDraftDecodesWithoutPickupAndInvalidSenderIsRejected() throws {
        let original = InvoiceDraft.Content()
        let restored = try JSONDecoder().decode(InvoiceDraft.Content.self, from: JSONEncoder().encode(original))
        XCTAssertNil(restored.pickup)
        let invalid = try JSONDecoder().decode(Pickup.self, from: Data(#"{"id":42,"completed":false}"#.utf8))
        XCTAssertThrowsError(try PickupInvoicePrefill.content(from: invalid))
    }

    #if os(iOS)
    func testNativeLinkedWizardRendersPickupAndCustomers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let content = try PickupInvoicePrefill.content(from: fixture(), receiverID: "000000000000000000000002")
        let editor = InvoiceDraftEditorModel(initialContent: content, store: store, isAuthorized: { true })
        editor.content.wizardStep = .customers
        let host = UIHostingController(rootView: InvoiceDraftEditorView(model: editor)
            .environment(NetworkConnection()).environment(SynchronizationState())
            .environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        XCTAssertEqual(editor.content.pickup?.id, 42)
        XCTAssertEqual(editor.content.receiverName, "First recipient")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-invoice-\(device).png"))
    }
    #endif

    private func fixture() throws -> Pickup {
        try JSONDecoder().decode(Pickup.self, from: Data(#"{"id":42,"completed":false,"sender":{"id":"000000000000000000000001","name":"Sender"},"receivers":[{"id":"000000000000000000000002","name":"First recipient"},{"id":"000000000000000000000003","name":"Second recipient"},{"id":"000000000000000000000003","name":"Duplicate recipient"}],"comments":[{"purpose":"Pickup","quantity":2,"description":"Instructions, not invoice items"}]}"#.utf8))
    }
}
