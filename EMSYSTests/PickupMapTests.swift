import XCTest
#if os(iOS)
import SwiftUI
import UIKit
import MapKit
#endif
@testable import EMSYS

@MainActor
final class PickupMapTests: XCTestCase {
    func testGeoJSONCoordinatesSurviveSQLiteReopenAndStayWithThePickupAddress() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await PickupStore.open(directory: directory, userID: "driver", companyID: "company")
        let pickup = try fixture(id: 1, coordinates: [-73.94, 40.84])
        try await store.save([pickup])
        let reopened = try await PickupStore.open(directory: directory, userID: "driver", companyID: "company")
        let restored = try await reopened.pickup(id: 1)
        let saved = try XCTUnwrap(restored)
        let coordinate = try XCTUnwrap(PickupMapModel.coordinate(for: saved))
        XCTAssertEqual(coordinate.longitude, -73.94)
        XCTAssertEqual(coordinate.latitude, 40.84)
        XCTAssertEqual(saved.sender?.displayAddress, "120 Broadway, New York, NY")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var sender = try XCTUnwrap(payload["sender"] as? [String: Any])
        sender["address"] = ["address1": "Pickup street"]
        sender["addresses"] = [["address1": "Different street", "isPrimary": true,
                                "location": ["type": "Point", "coordinates": [-70, 20]]]]
        payload["sender"] = sender
        let different = try JSONDecoder().decode(Pickup.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(PickupMapModel.coordinate(for: different))
        XCTAssertEqual(different.sender?.displayAddress, "Pickup street")
    }

    func testInvalidOrMissingLocationsRemainInTheListWithoutInventedPins() throws {
        let coordinates: [[Double]?] = [nil, [], [10], [10, 20, 30], [181, 20], [10, -91]]
        let pickups = try coordinates.enumerated().map { try fixture(id: UInt32($0.offset + 1), coordinates: $0.element) }
        let model = PickupMapModel(pickups: pickups)
        XCTAssertTrue(model.mappedPickups.isEmpty)
        XCTAssertEqual(model.missingLocationCount, pickups.count)
        XCTAssertEqual(model.pickups.count, pickups.count)
        XCTAssertNotNil(PickupMapModel.coordinate(for: try fixture(id: 9, coordinates: [0, 0])))
        let legacy = try JSONDecoder().decode(Pickup.self, from: Data(#"{"id":50,"completed":false,"sender":{"name":"Legacy"}}"#.utf8))
        XCTAssertNil(PickupMapModel.coordinate(for: legacy))
    }

    func testSelectionSurvivesExpansionButIsRemovedWhenFilteredOut() throws {
        let first = try fixture(id: 1, coordinates: [-73.94, 40.84])
        let second = try fixture(id: 2, coordinates: [-73.98, 40.75])
        let model = PickupMapModel(pickups: [first, second])
        model.selectedPickupID = second.id
        model.isExpanded = true
        model.showsExpandedList = true
        model.select(first.id)
        XCTAssertFalse(model.showsExpandedList)
        XCTAssertEqual(model.selectedPickupID, first.id)
        model.select(second.id)
        model.update([first, second])
        model.isExpanded = false
        XCTAssertEqual(model.selectedPickupID, second.id)
        model.update([first])
        XCTAssertNil(model.selectedPickupID)
        XCTAssertEqual(model.mappedPickups.map(\.id), [first.id])
    }

    #if os(iOS)
    func testNativeMapAndAddressListRenderInSpanish() async throws {
        let pickups = [try fixture(id: 1, coordinates: [-73.94, 40.84]),
                       try fixture(id: 2, coordinates: nil),
                       try fixture(id: 3, coordinates: [-73.98, 40.75])]
        let model = PickupMapModel(pickups: pickups)
        model.selectedPickupID = 1
        let host = UIHostingController(rootView: NavigationStack {
            PickupMapView(model: model) { Text(verbatim: "#\($0.id)") }
                .navigationTitle("navigation.pickups")
        }.environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-map-\(device).png"))
        model.isExpanded = true
        try await Task.sleep(for: .milliseconds(700))
        let presentation = try XCTUnwrap(host.presentedViewController)
        XCTAssertNil(findMap(in: host.view), "The compact map must be unmounted while the full-screen map owns selection")
        let map = try XCTUnwrap(findMap(in: presentation.view))
        let annotation = try XCTUnwrap(map.annotations.first {
            abs($0.coordinate.longitude - (-73.98)) < 0.00001
        })
        map.selectAnnotation(annotation, animated: false)
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.selectedPickupID != 3, ContinuousClock.now < selectionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.selectedPickupID, 3)
        // MapKit writes the same binding as a user's pin tap. Re-selecting pins
        // must not prevent the list drawer and restore controls from working.
        if let firstAnnotation = map.annotations.first(where: {
            abs($0.coordinate.longitude - (-73.94)) < 0.00001
        }) {
            map.selectAnnotation(firstAnnotation, animated: false)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.selectedPickupID, 1)
        } else { XCTFail("Expected the first pickup pin") }
        let expanded = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(expanded.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-map-full-\(device).png"))
        model.showsExpandedList = true
        try await Task.sleep(for: .milliseconds(700))
        let drawer = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(drawer.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-map-drawer-\(device).png"))
        model.select(2)
        XCTAssertFalse(model.showsExpandedList)
        try await Task.sleep(for: .milliseconds(700))
        model.select(1)
        model.isExpanded = false
        let dismissalDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while host.presentedViewController != nil, ContinuousClock.now < dismissalDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(host.presentedViewController)
        XCTAssertNotNil(findMap(in: host.view), "The compact map must be restored after dismissing full-screen mode")
        XCTAssertEqual(model.selectedPickupID, 1)
        window.overrideUserInterfaceStyle = .dark
        host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        try await Task.sleep(for: .milliseconds(500))
        let dark = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(dark.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-map-dark-\(device).png"))
    }
    private func findMap(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { self.findMap(in: $0) }.first
    }
    #endif

    private func fixture(id: UInt32, coordinates: [Double]?) throws -> Pickup {
        var address: [String: Any] = ["address1": "120 Broadway", "city": "New York", "state": "NY"]
        if let coordinates { address["location"] = ["type": "Point", "coordinates": coordinates] }
        let payload: [String: Any] = ["id": id, "completed": false,
            "sender": ["name": id == 1 ? "María García" : "José Pérez", "address": address]]
        return try JSONDecoder().decode(Pickup.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
