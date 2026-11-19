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
        let model = InvoiceDraftEditorViewModel(store: store, isAuthorized: { true })
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
    /// Checks catalog price focus and preserves saved overrides when editing the visible fields.
    func testCatalogDescriptionFocusesTheEmptyPriceField() async throws {
        // Set up two lines, including an older line with a custom label count and total.
        let fixture = ItemPriceFocusFixture()
        let host = UIHostingController(rootView: Form {
            ForEach(fixture.items.indices, id: \.self) { index in
                // Bind each form section to its corresponding draft line.
                @Bindable var fixture = fixture
                InvoiceDraftItemFields(item: $fixture.items[index], priceFocusRequest: $fixture.request,
                    chooseDescription: {}, remove: {}, usesMobileLayout: UIDevice.current.userInterfaceIdiom == .phone)
            }
        })
        // Host the fields in a native window so the numeric keyboard can take focus.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }

        // Simulate picking a catalog item and wait for the empty price field to receive native focus.
        try await Task.sleep(for: .milliseconds(300))
        fixture.items[0].unitPrice = ""
        fixture.request = fixture.items[0].id
        for _ in 0..<20 {
            if fixture.request == nil, focusedTextInput(in: host.view) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Confirm the focused field is empty and ready for new numeric input.
        let input = try XCTUnwrap(focusedTextInput(in: host.view))
        XCTAssertEqual((input as? UITextField)?.keyboardType, .decimalPad)
        XCTAssertFalse(input.hasText)
        XCTAssertNil(fixture.request)
        try capture(window, name: "item-fields")

        // Entering the new price must preserve the second line and legacy overrides.
        input.insertText("7")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.items[0].unitPrice, "7")
        XCTAssertEqual(fixture.items[1].unitPrice, "80")
        XCTAssertEqual(fixture.items[0].labelCount, "2")
        XCTAssertEqual(fixture.items[0].total, "30")
        let amounts = try InvoiceDraftAmounts(items: [fixture.items[0]])
        XCTAssertEqual(amounts.subtotal, 30)
    }

    /// Renders the native description picker with manual entry and a preloaded catalog.
    func testNativeDescriptionPickerRendersManualEntryAndCachedDescriptions() async throws {
        // Seed the same local catalog used when the app is offline.
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let catalog = [
            InvoiceCatalogItem(id: 1, name: "Caja de ropa", price: 25, createdAt: nil),
            InvoiceCatalogItem(id: 2, name: "Barril", price: 80, createdAt: nil),
        ]
        try await store.saveItemCatalog(catalog)
        let model = InvoiceDraftEditorViewModel(store: store, canViewItemCatalog: { true }, isAuthorized: { true })
        await model.loadItemCatalog(online: false)
        XCTAssertEqual(Set(model.catalogItems.map(\.name)), Set(catalog.map(\.name)))

        // Capture a picker with an existing manual description ready to edit.
        let picker = InvoiceItemDescriptionPicker(model: model, description: "Caja") { _ in
            XCTFail("Displaying the picker must not confirm its description")
        }
        let host = UIHostingController(rootView: picker
            .environment(NetworkConnection())
            .environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(400))
        // The same field both holds the description and narrows the catalog.
        let fields = descriptionInputs(in: host.view)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.text, "Caja")
        try capture(window, name: "description-picker")
    }

    /// Finds editable multiline description fields in the native picker.
    private func descriptionInputs(in view: UIView) -> [UITextView] {
        // Collect text views without counting the catalog rows or navigation controls.
        if let field = view as? UITextView {
            return [field]
        }
        return view.subviews.flatMap { descriptionInputs(in: $0) }
    }

    private func focusedTextInput(in view: UIView) -> (any UITextInput)? {
        if view.isFirstResponder, let input = view as? any UITextInput { return input }
        return view.subviews.lazy.compactMap { self.focusedTextInput(in: $0) }.first
    }

    /// Renders the invoice wizard, saved-draft feedback, and adaptive item fields.
    func testNativeCustomerAndItemFieldsRenderWithSelectedAddressesAndAccessibleLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let deviceID = try await store.invoicePoolDeviceID()
        let reserved = InvoiceReservation(id: "507f1f77bcf86cd799439013", number: "NY-10452",
            allocation: .init(userId: 12, token: UUID().uuidString, deviceId: deviceID.uuidString))
        try await store.reconcileInvoiceReservations([reserved], lowThreshold: 10)
        let customer = try JSONDecoder().decode(InvoiceCustomer.self, from: Data("""
            {"id":"507f1f77bcf86cd799439011","name":"Alejandra García Hernández","customerType":1,
             "phones":[{"number":"809-555-0100"}],
             "addresses":[{"id":"507f1f77bcf86cd799439012","address1":"Calle Principal 123, apartamento 4","city":"Santo Domingo"}]}
            """.utf8))
        var content = InvoiceDraft.Content()
        content.wizardStep = .details
        content.senderName = customer.name
        content.senderCustomer = customer
        content.senderAddressID = customer.addresses?.first?.id
        content.receiverName = "Juan Luna García"
        content.items = [.init(name: "Caja de ropa y artículos del hogar para la familia", quantity: "2", unitPrice: "25", labelCount: "2")]
        let model = InvoiceDraftEditorViewModel(initialContent: content, store: store,
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
        XCTAssertEqual(model.nextInvoiceNumber, reserved.number)
        try capture(window, name: "reserved-number")
        // Saving keeps the editor visible and confirms that the local draft committed.
        await model.save()
        XCTAssertTrue(model.didSave)
        XCTAssertFalse(model.hasChanges)
        try await Task.sleep(for: .milliseconds(250))
        try capture(window, name: "draft-saved")
        model.continueCreation()
        XCTAssertEqual(model.step, .customers)
        try await Task.sleep(for: .milliseconds(500))
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
        host.traitOverrides.preferredContentSizeCategory = .large
        model.content.wizardStep = .review
        XCTAssertFalse(model.skipsSignature)
        try await Task.sleep(for: .milliseconds(500))
        let reviewScroll = try XCTUnwrap(findScrollView(in: host.view))
        reviewScroll.setContentOffset(CGPoint(x: 0, y: max(0, reviewScroll.contentSize.height - reviewScroll.bounds.height
            + reviewScroll.adjustedContentInset.bottom)), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window, name: "signature-default")
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

#if os(iOS)
@MainActor
@Observable
private final class ItemPriceFocusFixture {
    var items: [InvoiceDraft.Item] = [
        .init(name: "Caja de ropa", unitPrice: "25", labelCount: "2", total: "30"),
        .init(name: "Barril", unitPrice: "80"),
    ]
    var request: UUID?
}
#endif
