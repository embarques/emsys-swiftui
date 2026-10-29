import XCTest
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import EMSYS

@MainActor
final class PickupInvoiceContextTests: XCTestCase {
    private let senderID = "507f1f77bcf86cd799439011"
    private let receiverID = "507f1f77bcf86cd799439012"

    func testPreparedCustomersPersistOfflineWithFirstAddressesAndSameAPIFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pickup = try pickup()
        let context = try context()
        let store = try await PickupStore.open(directory: directory, userID: "driver", companyID: "tenant")
        try await store.save([pickup])
        try await store.save(PickupSyncSnapshot(pickup: pickup, revision: context.revision, invoiceContexts: [context]))
        let reopened = try await PickupStore.open(directory: directory, userID: "driver", companyID: "tenant")
        let cached = try await reopened.invoiceContext(pickup: pickup, receiverID: receiverID)
        let content = try XCTUnwrap(cached).content(from: pickup, receiverID: receiverID)
        XCTAssertEqual(content.senderName, "Current Sender")
        XCTAssertEqual(content.senderWriteSnapshot?.identityNumber, "identity")
        XCTAssertEqual(content.senderAddressID, "507f1f77bcf86cd799439013")
        XCTAssertEqual(content.receiverAddressID, "507f1f77bcf86cd799439014")
        XCTAssertEqual(content.pickup?.id, 42)
        XCTAssertTrue(content.items.allSatisfy { $0.name.isEmpty && $0.unitPrice.isEmpty })
        let foreign = try await PickupStore.open(directory: directory, userID: "another", companyID: "tenant")
        let foreignContext = try await foreign.invoiceContext(pickup: pickup, receiverID: receiverID)
        XCTAssertNil(foreignContext)
        try await reopened.save(PickupSyncSnapshot(pickup: pickup, revision: context.revision, invoiceContexts: []))
        let revoked = try await reopened.invoiceContext(pickup: pickup, receiverID: receiverID)
        XCTAssertNil(revoked)
        try await reopened.saveInvoiceContext(context, pickup: pickup, receiverID: receiverID)
        try await reopened.remove(id: pickup.id)
        let hidden = try await reopened.invoiceContext(pickup: pickup, receiverID: receiverID)
        XCTAssertNil(hidden)
    }

    func testForeignCustomersAndChangedPickupRecipientsAreRejected() async throws {
        let context = try context()
        let pickup = try pickup()
        XCTAssertFalse(context.matches(pickup, receiverID: senderID))
        let changed = try JSONDecoder().decode(Pickup.self, from: Data("""
            {"id":42,"completed":false,"sender":{"id":"\(senderID)","name":"Sender"},"receivers":[]}
            """.utf8))
        XCTAssertFalse(context.matches(changed, receiverID: nil))
        let wrong = PickupInvoiceContext(pickupId: 43, revision: context.revision, sender: context.sender, receiver: context.receiver)
        XCTAssertThrowsError(try wrong.content(from: pickup, receiverID: receiverID))
    }

    #if os(iOS)
    func testNativePreparedWizardShowsSelectedCustomerAddresses() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        var content = try context().content(from: pickup(), receiverID: receiverID)
        content.wizardStep = .customers
        content.assignedPickup = InvoiceAssignedPickup(pickupID: 42, senderID: senderID, receiverID: receiverID)
        let editor = InvoiceDraftEditorModel(assignedOnlyAccess: true, initialContent: content, store: store, isAuthorized: { true })
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
        XCTAssertEqual(editor.content.senderAddressID, "507f1f77bcf86cd799439013")
        XCTAssertEqual(editor.content.receiverAddressID, "507f1f77bcf86cd799439014")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-prepared-invoice-\(device).png"))
    }
    #endif

    private func pickup() throws -> Pickup {
        try JSONDecoder().decode(Pickup.self, from: Data("""
            {"id":42,"completed":false,"sender":{"id":"\(senderID)","name":"Historical sender"},
             "receivers":[{"id":"\(receiverID)","name":"Historical receiver"}]}
            """.utf8))
    }

    private func context() throws -> PickupInvoiceContext {
        try JSONDecoder().decode(PickupInvoiceContext.self, from: Data("""
            {"pickupId":42,"revision":"v1:\(String(repeating: "a", count: 64))",
             "sender":{"id":"\(senderID)","name":"Current Sender","customerType":1,"IDNumber":"identity",
                       "addresses":[{"id":"507f1f77bcf86cd799439013","address1":"Sender Street"}]},
             "receiver":{"id":"\(receiverID)","name":"Current Receiver","customerType":2,
                         "addresses":[{"id":"507f1f77bcf86cd799439014","address1":"Receiver Street"}]}}
            """.utf8))
    }
}
