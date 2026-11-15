#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import EMSYS

@MainActor
final class ConnectionStatusLayoutTests: XCTestCase {
    /// Checks the sync toolbar while the invoice messages and rows scroll beneath it.
    func testSyncWarningToolbarRendersAboveScrolledInvoiceRows() async throws {
        // Trigger the synchronization warning before presenting the invoice fixture.
        let state = SynchronizationState()
        await state.synchronize { throw InvoiceMutationUploader.UploadError.attentionRequired }
        let content = AppTabNavigationView(selection: .constant(.invoices)) { _ in
            NavigationStack {
                List {
                    InvoicePoolWarningView(issue: nil, count: 0, threshold: 10, openPool: {})
                    ForEach(1...40, id: \.self) { index in
                        Text("Factura de prueba \(index)")
                            .listRowBackground(Color.blue)
                    }
                }
                    .navigationTitle("Facturas")
                    .toolbar {
                        Button {} label: { Label("Crear factura", systemImage: "plus") }
                        Button {} label: { Label("Actualizar facturas", systemImage: "arrow.clockwise") }
                        Button {} label: { Label("Acciones de facturas", systemImage: "ellipsis.circle") }
                    }
                    .connectionStatus()
            }
        }
        .environment(NetworkConnection())
        .environment(state)
        .environment(\.locale, Locale(identifier: "es-DO"))
        // Use the active simulator window to exercise native navigation and toolbar layout.
        let host = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        // Move past the inline message before capturing the pinned sync indicator.
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
