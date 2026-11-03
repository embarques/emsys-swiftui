import MapKit
import SwiftUI

/// Keeps MapKit selection callbacks separate from SwiftUI's view update cycle.
struct PickupMapCanvas {
    let pickups: [Pickup]
    @Binding var selectedPickupID: UInt32?
    let fitRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selectedPickupID) }

    func makeMap(coordinator: Coordinator) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = coordinator
        map.showsCompass = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pickup")
        return map
    }

    func updateMap(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.update(map, pickups: pickups, selection: $selectedPickupID, fitRequest: fitRequest)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var selection: Binding<UInt32?>
        private var annotations: [UInt32: PickupMapAnnotation] = [:]
        private var lastSelection: UInt32?
        private var lastFitRequest = 0
        private var hasFitted = false
        private var isUpdating = false
        private var isActive = true

        init(selection: Binding<UInt32?>) { self.selection = selection }

        func update(_ map: MKMapView, pickups: [Pickup], selection: Binding<UInt32?>, fitRequest: Int) {
            self.selection = selection
            isUpdating = true
            defer { isUpdating = false }
            let mapped = pickups.compactMap { pickup -> PickupMapAnnotation? in
                guard let coordinate = PickupMapModel.coordinate(for: pickup) else { return nil }
                return PickupMapAnnotation(id: pickup.id, title: pickup.sender?.name ?? "#\(pickup.id)", coordinate: coordinate)
            }
            let ids = Set(mapped.map(\.id))
            var locationsChanged = false
            for id in Array(annotations.keys) where !ids.contains(id) {
                if let removed = annotations.removeValue(forKey: id) { map.removeAnnotation(removed) }
                locationsChanged = true
            }
            for pin in mapped {
                if let existing = annotations[pin.id] {
                    if existing.coordinate.latitude != pin.coordinate.latitude || existing.coordinate.longitude != pin.coordinate.longitude {
                        existing.coordinate = pin.coordinate
                        locationsChanged = true
                    }
                    if existing.title != pin.title { existing.title = pin.title }
                } else {
                    annotations[pin.id] = pin
                    map.addAnnotation(pin)
                    locationsChanged = true
                }
            }
            let selectedID = selection.wrappedValue
            let selectionChanged = selectedID != lastSelection
            let shouldFit = !hasFitted || locationsChanged || fitRequest != lastFitRequest
            lastSelection = selectedID
            lastFitRequest = fitRequest
            if let selectedID, let pin = annotations[selectedID] {
                if !map.selectedAnnotations.contains(where: { ($0 as? PickupMapAnnotation)?.id == selectedID }) {
                    map.selectAnnotation(pin, animated: false)
                }
                if selectionChanged || shouldFit {
                    map.setRegion(MKCoordinateRegion(center: pin.coordinate, latitudinalMeters: 1800,
                        longitudinalMeters: 1800), animated: false)
                }
            } else {
                for pin in map.selectedAnnotations { map.deselectAnnotation(pin, animated: false) }
                if shouldFit, let first = mapped.first {
                    if mapped.allSatisfy({ $0.coordinate.latitude == first.coordinate.latitude && $0.coordinate.longitude == first.coordinate.longitude }) {
                        map.setRegion(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 1800,
                            longitudinalMeters: 1800), animated: false)
                    } else { map.showAnnotations(Array(annotations.values), animated: false) }
                }
            }
            hasFitted = !mapped.isEmpty
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard annotation is PickupMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pickup", for: annotation)
            view.canShowCallout = false
            if let marker = view as? MKMarkerAnnotationView {
                #if os(iOS)
                marker.markerTintColor = UIColor(AppStyle.Colors.accent)
                #else
                marker.markerTintColor = NSColor(AppStyle.Colors.accent)
                #endif
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isUpdating, isActive, let pin = view.annotation as? PickupMapAnnotation else { return }
            // A native callback can arrive while MapKit is laying out annotations.
            // Publish on the next main-actor turn, never inside updateUIView.
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.annotations[pin.id] === pin,
                      mapView.selectedAnnotations.contains(where: { ($0 as? PickupMapAnnotation)?.id == pin.id }),
                      self.selection.wrappedValue != pin.id else { return }
                self.selection.wrappedValue = pin.id
            }
        }

        func dismantle(_ map: MKMapView) {
            isActive = false
            map.delegate = nil
        }
    }
}

@MainActor
final class PickupMapAnnotation: NSObject, MKAnnotation {
    let id: UInt32
    @objc dynamic var title: String?
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(id: UInt32, title: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.title = title
        self.coordinate = coordinate
    }
}

#if os(iOS)
extension PickupMapCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateUIView(_ map: MKMapView, context: Context) { updateMap(map, coordinator: context.coordinator) }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { coordinator.dismantle(map) }
}
#else
extension PickupMapCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateNSView(_ map: MKMapView, context: Context) { updateMap(map, coordinator: context.coordinator) }
    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) { coordinator.dismantle(map) }
}
#endif
