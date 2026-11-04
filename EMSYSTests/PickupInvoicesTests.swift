import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class PickupInvoicesTests: XCTestCase {
    func testCreationPendingReviewAndReceiptReplaceCreateWithoutLosingThePickupLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var authorized = true
        var editable = true
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1"))) { _ in
            throw APIClientError.sessionChanged
        }
        let model = PickupInvoicesModel(pickupID: 42, store: store, client: client,
            isAuthorized: { authorized }, canEdit: { editable })
        XCTAssertFalse(model.mayCreate, "Creation must wait until existing invoices have been checked")
        await model.load()
        XCTAssertTrue(model.mayCreate)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan(pickupID: 42))
        await model.load()
        XCTAssertFalse(model.mayCreate)
        XCTAssertNil(model.links.first?.number, "An offline submission has no authoritative invoice number")
        XCTAssertNil(model.editor(for: try XCTUnwrap(model.links.first)))
        try await store.setInvoiceCreationState(id: operation.id, state: .needsReview)
        await model.load()
        XCTAssertEqual(model.links.first?.state, .needsReview)
        XCTAssertFalse(model.mayCreate)
        try await store.setInvoiceCreationState(id: operation.id, state: .pending)
        // A successful response can omit pickup. The durable request still links it.
        let invoice = try fixture(id: "000000000000000000000003", number: "NY-123", pickupID: nil)
        try await store.completeInvoiceCreation(id: operation.id, invoice: invoice)
        await model.load()
        let link = try XCTUnwrap(model.links.first)
        XCTAssertEqual(link.number, "NY-123")
        XCTAssertEqual(model.editor(for: link)?.invoiceID, invoice.id)
        editable = false
        XCTAssertNil(model.editor(for: link), "Losing update authority must close the edit path")
        authorized = false
        await model.load()
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertFalse(model.mayCreate)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.pickupInvoiceLinks(pickupID: 42)
        XCTAssertEqual(restored.map(\.number), ["NY-123"])
        let unrelated = try await reopened.pickupInvoiceLinks(pickupID: 43)
        XCTAssertTrue(unrelated.isEmpty)
        let otherCompany = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let foreign = try await otherCompany.pickupInvoiceLinks(pickupID: 42)
        XCTAssertTrue(foreign.isEmpty)
    }

    func testDownloadedInvoicesUseExactPickupIDsAndDoNotDuplicateCompletedReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan(pickupID: 42))
        let invoice = try fixture(id: "000000000000000000000003", number: "NY-123", pickupID: 42)
        try await store.completeInvoiceCreation(id: operation.id, invoice: invoice)
        try await store.saveDownloaded([invoice,
            fixture(id: "000000000000000000000004", number: "NY-124", pickupID: 42),
            fixture(id: "000000000000000000000005", number: "NY-125", pickupID: 43)])
        let links = try await store.pickupInvoiceLinks(pickupID: 42)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(Set(links.compactMap(\.number)), ["NY-123", "NY-124"])
    }

    private func plan(pickupID: UInt32) throws -> InvoiceCreationPlan {
        let customer = Data(#"{"id":"000000000000000000000001","name":"Sender","customerType":1}"#.utf8)
        var content = InvoiceDraft.Content()
        content.date = try XCTUnwrap(InvoiceDate(apiValue: "2026-11-03"))
        content.senderCustomer = try JSONDecoder().decode(InvoiceCustomer.self, from: customer)
        content.senderWriteSnapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: customer)
        content.senderName = "Sender"
        content.pickup = .init(id: pickupID)
        content.items = [.init(name: "Box", quantity: "1", unitPrice: "20", labelCount: "1")]
        content.policies = []
        content.paymentRegion = "NY"
        content.payment = InvoiceDraftPayment(mode: .skip)
        return try InvoiceCreationPlan(content: content, branch: .init(id: 1, name: "New York", code: "NY"))
    }

    private func fixture(id: String, number: String, pickupID: UInt32?) throws -> Invoice {
        var payload: [String: Any] = ["id": id, "number": number, "sender": ["name": "Sender"]]
        if let pickupID { payload["pickup"] = ["id": pickupID] }
        return try JSONDecoder().decode(Invoice.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    #if os(iOS)
    func testNativeLinkedInvoiceRowInSpanish() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveDownloaded([fixture(id: "000000000000000000000003", number: "NY-12345", pickupID: 42)])
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1"))) { _ in
            throw APIClientError.sessionChanged
        }
        let model = PickupInvoicesModel(pickupID: 42, store: store, client: client, isAuthorized: { true }, canEdit: { true })
        await model.load()
        let host = UIHostingController(rootView: List {
            Section { PickupInvoiceLinksView(model: model) { _ in } }
        }.environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            if dark { host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge }
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
                .appending(path: "emsys-pickup-invoice-\(device)-\(dark ? "dark" : "light").png"))
        }
    }
    #endif
}
