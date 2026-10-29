import Observation
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import EMSYS

@MainActor
final class AppNavigationTests: XCTestCase {
    func testDestinationsRespectAPIResourceGrantsWhileMoreRemainsAvailable() {
        let permissions = UserPermissions(role: .init(id: 1, name: "Invoice role"), permissions: [
            .init(name: "canViewInvoice", resourceType: "invoice"),
            .init(name: "canViewPickup", resourceType: "delivery")
        ])
        XCTAssertTrue(AppDestination.invoices.isAccessible(with: permissions))
        XCTAssertFalse(AppDestination.pickups.isAccessible(with: permissions))
        XCTAssertFalse(AppDestination.deliveries.isAccessible(with: permissions))
        XCTAssertFalse(AppDestination.dailyIncome.isAccessible(with: permissions))
        XCTAssertTrue(AppDestination.more.isAccessible(with: nil))
        XCTAssertTrue(AppDestination.settings.isAccessible(with: nil))
        let assigned = UserPermissions(role: .init(id: 2, name: "Field role"), permissions: [
            .init(name: "canViewAssignedAppointments", resourceType: "pickup"),
            .init(name: "canViewAssignedDeliveries", resourceType: "delivery")
        ])
        XCTAssertTrue(AppDestination.pickups.isAccessible(with: assigned))
        XCTAssertTrue(AppDestination.deliveries.isAccessible(with: assigned))
        XCTAssertFalse(AppDestination.invoices.isAccessible(with: assigned))
    }

    #if os(iOS)
    func testNativeTabSwitchPreservesInvoiceSearchAndRendersNavigation() async throws {
        let probe = NavigationProbe()
        let initial = expectation(description: "Invoice tab appears")
        probe.didAppear = { if $0 == .invoices { initial.fulfill() } }
        let host = UIHostingController(rootView: NavigationFixture(probe: probe)
            .environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await fulfillment(of: [initial], timeout: 5)
        probe.setSearch?("INV-LOCAL-42")
        XCTAssertEqual(probe.search?(), "INV-LOCAL-42")
        let more = expectation(description: "More tab appears")
        probe.didAppear = { if $0 == .more { more.fulfill() } }
        probe.selection = .more
        await fulfillment(of: [more], timeout: 5)
        let returned = expectation(description: "Invoice tab returns")
        probe.didSelect = { if $0 == .invoices { returned.fulfill() } }
        probe.selection = .invoices
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertEqual(probe.search?(), "INV-LOCAL-42", "Switching tabs must retain the invoice search")
        // Native tab selection animates independently of SwiftUI's onChange.
        // Let that transition settle before recording the rendered fixture.
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-navigation-\(device).png"))
    }
    #endif
}

#if os(iOS)
@MainActor
@Observable
private final class NavigationProbe {
    var selection: AppDestination = .invoices
    var didAppear: ((AppDestination) -> Void)?
    var didSelect: ((AppDestination) -> Void)?
    var setSearch: ((String) -> Void)?
    var search: (() -> String)?
}

private struct NavigationFixture: View {
    @Bindable var probe: NavigationProbe
    var body: some View {
        AppTabNavigationView(selection: $probe.selection) { destination in
            NavigationFixtureSection(destination: destination, probe: probe)
        }
        .onChange(of: probe.selection) { probe.didSelect?(probe.selection) }
    }
}

private struct NavigationFixtureSection: View {
    let destination: AppDestination
    let probe: NavigationProbe
    @State private var search = ""
    var body: some View {
        List {
            TextField("Buscar factura", text: $search)
            NavigationLink("Ver detalles") { Text("Factura de prueba") }
        }
        .navigationTitle(destination.title)
        .onAppear {
            if destination == .invoices {
                probe.setSearch = { search = $0 }
                probe.search = { search }
            }
            probe.didAppear?(destination)
        }
    }
}
#endif
