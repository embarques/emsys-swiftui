import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class InvoiceWizardLayoutTests: XCTestCase {
    func testItemEditsAndRemovalPreserveTheRemainingValuesAfterReopeningSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        let removed = InvoiceDraft.Item(name: "Remove", unitPrice: "10")
        let retained = InvoiceDraft.Item(name: "Caja de ropa", quantity: "1.5", unitPrice: "20", labelCount: "2", total: "25")
        model.content.items = [removed, retained]
        model.removeItem(id: removed.id)
        XCTAssertEqual(model.content.items, [retained])
        XCTAssertEqual(model.amounts?.subtotal, 25)
        let saved = try await store.saveDraft(id: UUID(), content: model.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let restored = try await reopened.draft(id: saved.id)
        XCTAssertEqual(restored?.content.items, [retained])
    }

    #if os(iOS)
    func testNativeCustomerAndItemFieldsRenderWithSelectedAddressesAndAccessibleLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let customer = try JSONDecoder().decode(InvoiceCustomer.self, from: Data("""
            {"id":"507f1f77bcf86cd799439011","name":"Alejandra García Hernández","customerType":1,
             "phones":[{"number":"809-555-0100"}],
             "addresses":[{"id":"507f1f77bcf86cd799439012","address1":"Calle Principal 123, apartamento 4","city":"Santo Domingo"}]}
            """.utf8))
        var content = InvoiceDraft.Content()
        content.wizardStep = .customers
        content.senderName = customer.name
        content.senderCustomer = customer
        content.senderAddressID = customer.addresses?.first?.id
        content.receiverName = "Juan Luna García"
        content.items = [.init(name: "Caja de ropa y artículos del hogar para la familia", quantity: "2", unitPrice: "25", labelCount: "2")]
        let model = InvoiceDraftEditorModel(initialContent: content, store: store,
            canViewItemCatalog: { true }, isAuthorized: { true })
        let host = UIHostingController(rootView: InvoiceDraftEditorView(model: model)
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
        try capture(window, name: "customers")
        model.continueCreation()
        XCTAssertEqual(model.step, .items)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, name: "items")
        XCTAssertEqual(model.amounts?.subtotal, 50)
        window.overrideUserInterfaceStyle = .dark
        host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(findScrollView(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: min(250, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window, name: "items-accessible")
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        XCTAssertEqual(model.content.senderAddressID, customer.addresses?.first?.id)
    }

    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
            .appending(path: "emsys-wizard-\(name)-\(device).png"))
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
    #endif
}
