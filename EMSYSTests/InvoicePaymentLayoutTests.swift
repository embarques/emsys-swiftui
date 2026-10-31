#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import EMSYS

@MainActor
final class InvoicePaymentLayoutTests: XCTestCase {
    func testNativePaymentSelectionAndConditionalDetailsRenderInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        var content = InvoiceDraft.Content()
        content.wizardStep = .payment
        content.items = [.init(name: "Caja", unitPrice: "385")]
        content.payment = .init(mode: .record, amount: "100", method: .cash)
        let model = InvoiceDraftEditorModel(initialContent: content, store: store,
            financialPermission: { _ in true }, isAuthorized: { true })
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
        try capture(window, name: "selection")
        XCTAssertEqual(model.paymentTotals?.balance, 285)
        let scroll = try XCTUnwrap(findScrollView(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: min(280, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window, name: "methods")
        model.setPaymentMethod(.check)
        model.content.payment?.bankAccount = .init(id: 1, name: "Banco de prueba", displayName: nil, type: "BANK")
        model.content.payment?.checkNumber = "000123"
        window.overrideUserInterfaceStyle = .dark
        host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        try await Task.sleep(for: .milliseconds(500))
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window, name: "details-accessible")
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        XCTAssertNil(model.content.payment?.validationIssue(subtotal: 385))
    }

    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
            .appending(path: "emsys-payment-\(name)-\(device).png"))
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
#endif
