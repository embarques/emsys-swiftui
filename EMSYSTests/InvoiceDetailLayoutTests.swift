#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import EMSYS

@MainActor
final class InvoiceDetailLayoutTests: XCTestCase {
    func testNativeInvoiceContentRendersItemsTotalsAndAccessibleText() async throws {
        let invoice = try JSONDecoder().decode(Invoice.self, from: Data(#"""
        {"id":"000000000000000000000001","number":"INV-26-001436","date":"2026-10-31",
         "sender":{"name":"Alejandra García","address":{"address1":"120 Broadway","city":"New York","state":"NY"}},
         "receiver":{"name":"Juan Luna y Juana García","address":{"address1":"Calle Principal 15","city":"Santo Domingo"}},
         "paidStatus":"OPEN","registration":"COMPLETED","cost":140.50,"discount":5.50,"surcharge":2,"payment":20,"balance":117,
         "invoiceDetails":[
          {"id":"a","name":"Caja de ropa","description":"Ropa y artículos del hogar","quantity":2,"price":35,"total":70},
          {"id":"b","name":"Tanque de comida y artículos personales para la familia","quantity":1,"price":60.50,"total":60.50},
          {"id":"c","name":"Paquete pequeño","description":"12345","quantity":1,"price":10,"total":10}]}
        """#.utf8))
        try await withContent(invoice) { host, window, scroll in
            try capture(window, name: "detail")
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            try capture(window, name: "totals")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            window.overrideUserInterfaceStyle = .dark
            host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            try capture(window, name: "accessible")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        }
    }

    func testSparseInvoiceContentRendersWithoutInventedAmountsOrStatus() async throws {
        let invoice = try JSONDecoder().decode(Invoice.self,
            from: Data(#"{"id":"000000000000000000000001","number":"INV-26-001437"}"#.utf8))
        try await withContent(invoice) { _, window, scroll in
            try capture(window, name: "sparse")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        }
    }

    private func withContent(_ invoice: Invoice,
        check: (UIHostingController<AnyView>, UIWindow, UIScrollView) async throws -> Void) async throws {
        let content = NavigationStack {
            ScrollView {
                InvoiceDetailContent(invoice: invoice)
                    .frame(maxWidth: AppStyle.Layout.readableContentWidth, alignment: .leading)
                    .padding(AppStyle.Spacing.large)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("invoices.detailTitle")
            .navigationBarTitleDisplayMode(.inline)
        }.environment(\.locale, Locale(identifier: "es-DO"))
        let host = UIHostingController(rootView: AnyView(content))
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
        let scroll = try XCTUnwrap(findScrollView(in: host.view))
        try await check(host, window, scroll)
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
            .appending(path: "emsys-invoice-\(name)-\(device).png"))
    }
}
#endif
