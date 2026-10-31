import CoreLocation
import Observation

/// Uses only the authorized list's downloaded records, never a second map query.
@MainActor
@Observable
final class PickupMapModel {
    private(set) var pickups: [Pickup]
    var selectedPickupID: UInt32?
    var isExpanded = false
    var showsExpandedList = false

    init(pickups: [Pickup]) { self.pickups = pickups }

    var mappedPickups: [Pickup] { pickups.filter { Self.coordinate(for: $0) != nil } }
    var missingLocationCount: Int { pickups.count - mappedPickups.count }

    func select(_ pickupID: UInt32) {
        guard pickups.contains(where: { $0.id == pickupID }) else { return }
        selectedPickupID = pickupID
        if isExpanded { showsExpandedList = false }
    }

    func update(_ pickups: [Pickup]) {
        self.pickups = pickups
        if let selectedPickupID, !pickups.contains(where: { $0.id == selectedPickupID }) {
            self.selectedPickupID = nil
        }
    }

    nonisolated static func coordinate(for pickup: Pickup) -> CLLocationCoordinate2D? {
        guard let location = pickup.sender?.selectedAddress?.location,
              location.type == "Point", location.coordinates.count == 2 else { return nil }
        // GeoJSON is longitude first. Zero is valid; never substitute a different
        // customer address when the actual pickup address has no location.
        let longitude = location.coordinates[0]
        let latitude = location.coordinates[1]
        guard longitude.isFinite, latitude.isFinite,
              (-180...180).contains(longitude), (-90...90).contains(latitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
