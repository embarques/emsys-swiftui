#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import EMSYS

@MainActor
final class ConnectionStatusLayoutTests: XCTestCase {
    func testInvoiceWarningsRenderOverScrolledRowsWithoutCoveringToolbar() async throws {
        let state = SynchronizationState()
        await state.synchronize { throw InvoiceMutationUploader.UploadError.attentionRequired }
        let content = AppTabNavigationView(selection: .constant(.invoices)) { _ in
            List(1...40, id: \.self) { index in
                Text("Factura de prueba \(index)")
                    .listRowBackground(Color.blue)
            }
                .navigationTitle("Facturas")
                .toolbar {
                    Button {} label: { Label("Crear factura", systemImage: "plus") }
                    Button {} label: { Label("Actualizar facturas", systemImage: "arrow.clockwise") }
                    Button {} label: { Label("Acciones de facturas", systemImage: "ellipsis.circle") }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    InvoicePoolWarningView(issue: nil, count: 5, threshold: 10, openPool: {})
                }
                .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
        }
        .environment(NetworkConnection())
        .environment(state)
        .environment(\.locale, Locale(identifier: "es-DO"))
        let host = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: 280), animated: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        let png = try XCTUnwrap(UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-connection-status-\(device).png"))
        XCTAssertTrue(state.requiresReview)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

}
#endif
