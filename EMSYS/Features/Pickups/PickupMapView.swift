import MapKit
import SwiftUI

struct PickupMapView<Detail: View>: View {
    @Bindable var model: PickupMapModel
    let isLoading: Bool
    let hasMore: Bool
    let loadMore: () -> Void
    let detail: (Pickup) -> Detail
    @State private var camera: MapCameraPosition = .automatic

    init(model: PickupMapModel, isLoading: Bool = false, hasMore: Bool = false,
         loadMore: @escaping () -> Void = {}, @ViewBuilder detail: @escaping (Pickup) -> Detail) {
        self.model = model
        self.isLoading = isLoading
        self.hasMore = hasMore
        self.loadMore = loadMore
        self.detail = detail
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    mapCanvas(expanded: false)
                    addressList.frame(width: min(380, geometry.size.width * 0.42))
                }
            } else {
                VStack(spacing: 0) {
                    mapCanvas(expanded: false)
                        .frame(height: max(180, geometry.size.height * 0.43))
                    addressList
                }
            }
        }
        .onAppear { focusSelection() }
        .onChange(of: model.pickups) { focusSelection() }
        .onChange(of: model.selectedPickupID) { focusSelection() }
        #if os(iOS)
        .fullScreenCover(isPresented: $model.isExpanded) { expandedMap }
        #else
        .sheet(isPresented: $model.isExpanded) {
            expandedMap.frame(minWidth: 800, idealWidth: 1100, minHeight: 600, idealHeight: 800)
        }
        #endif
    }

    private var expandedMap: some View {
        NavigationStack {
            mapCanvas(expanded: true)
                .navigationTitle("pickups.map")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("pickups.map.restore") { model.isExpanded = false }
                    }
                }
        }
        .sheet(isPresented: $model.showsExpandedList) {
            NavigationStack {
                addressList
                    .navigationTitle("pickups.map.addresses")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("documents.close") { model.showsExpandedList = false }
                        }
                    }
            }
            #if os(iOS)
            .presentationBackground(.background)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            #else
            .frame(minWidth: 360, minHeight: 400)
            #endif
        }
    }

    private func mapCanvas(expanded: Bool) -> some View {
        Map(position: $camera, selection: $model.selectedPickupID) {
            ForEach(model.mappedPickups) { pickup in
                if let coordinate = PickupMapModel.coordinate(for: pickup) {
                    Marker(pickup.sender?.name ?? "#\(pickup.id)", coordinate: coordinate)
                        .tint(AppStyle.Colors.accent)
                        .tag(pickup.id)
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .overlay(alignment: .bottomLeading) {
            if expanded {
                Button { model.showsExpandedList = true } label: {
                    Label("pickups.map.addresses", systemImage: "list.bullet")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(16)
                .padding(.bottom, 32)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack {
                Button { model.selectedPickupID = nil; camera = .automatic } label: {
                    Label("pickups.map.fit", systemImage: "scope")
                }
                if !expanded {
                    Button { model.isExpanded = true } label: {
                        Label("pickups.map.expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            if model.mappedPickups.isEmpty {
                Label("pickups.map.noCoordinates", systemImage: "mappin.slash")
                    .font(.callout).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(12)
                    .padding(.bottom, expanded ? 92 : 24)
            }
        }
    }

    private var addressList: some View {
        ScrollViewReader { scroll in
            List {
                Section {
                    if !model.isExpanded {
                        Text("pickups.map.hint").font(.caption).foregroundStyle(.secondary)
                        if model.missingLocationCount > 0 {
                            Label("pickups.map.missingLocations", systemImage: "mappin.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.pickups) { pickup in
                        addressRow(pickup).id(pickup.id)
                    }
                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if hasMore {
                        Button("pickups.loadMore", action: loadMore).disabled(isLoading)
                    }
                    if model.pickups.isEmpty, !isLoading {
                        ContentUnavailableView("pickups.empty", systemImage: "shippingbox")
                    }
                } header: { if !model.isExpanded { Text("pickups.map.addresses") } }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.background)
            .onChange(of: model.selectedPickupID) {
                if let id = model.selectedPickupID {
                    withAnimation { scroll.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func addressRow(_ pickup: Pickup) -> some View {
        let selected = model.selectedPickupID == pickup.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.select(pickup.id)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "mappin.circle.fill" : "mappin.circle")
                        .font(.title2).foregroundStyle(AppStyle.Colors.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: pickup.sender?.name ?? "#\(pickup.id)").font(.headline)
                        Text(verbatim: pickup.sender?.displayAddress.isEmpty == false
                            ? pickup.sender?.displayAddress ?? "" : String(localized: "pickups.map.noAddress"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: "#\(pickup.id)").font(.caption).foregroundStyle(.secondary)
                        if PickupMapModel.coordinate(for: pickup) == nil {
                            Text("pickups.map.locationUnavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").foregroundStyle(AppStyle.Colors.accent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink("pickups.map.details") { detail(pickup) }
                    if let url = pickup.directionsURL { Link("pickups.directions", destination: url) }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(selected ? AppStyle.Colors.accent.opacity(0.10) : Color.clear)
    }

    private func focusSelection() {
        if let pickup = model.pickups.first(where: { $0.id == model.selectedPickupID }),
           let coordinate = PickupMapModel.coordinate(for: pickup) {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1800, longitudinalMeters: 1800))
        } else { camera = .automatic }
    }
}
