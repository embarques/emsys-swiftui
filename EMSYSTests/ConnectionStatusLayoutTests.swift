#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import EMSYS

@MainActor
final class ConnectionStatusLayoutTests: XCTestCase {
    /// Verifies the sync warning starts at the top and moves with the invoice rows.
    func testSyncWarningScrollsWithInvoiceRows() async throws {
        // Trigger the synchronization warning before presenting the invoice fixture.
        let state = SynchronizationState()
        await state.synchronize { throw InvoiceMutationUploader.UploadError.attentionRequired }
        let content = AppTabNavigationView(selection: .constant(.invoices)) { _ in
            NavigationStack {
                List {
                    // The warning goes in the first native list row.
                    ConnectionStatusView()
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
        // Capture the warning at the top, then move it above the visible viewport.
        let list = try XCTUnwrap(collectionView(in: host.view))
        let warningIndex = IndexPath(item: 0, section: 0)
        XCTAssertTrue(list.indexPathsForVisibleItems.contains(warningIndex))
        try capture(window, stage: "top")
        list.scrollToItem(at: IndexPath(item: 12, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(list.contentOffset.y, 0)
        XCTAssertFalse(list.indexPathsForVisibleItems.contains(warningIndex))
        try capture(window, stage: "scrolled")
        XCTAssertTrue(state.requiresReview)
    }

    /// Saves the native rendering for visual review at each scroll position.
    private func capture(_ window: UIWindow, stage: String) throws {
        // Capture the navigation chrome and directory together.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let fileName = "emsys-connection-status-\(device)-\(stage).png"
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: fileName))
    }

    /// Finds the native collection backing the SwiftUI list.
    private func collectionView(in view: UIView) -> UICollectionView? {
        // Unwrap nested navigation and tab containers until the list is reached.
        if let list = view as? UICollectionView {
            return list
        }
        return view.subviews.lazy.compactMap { self.collectionView(in: $0) }.first
    }

}
#endif
