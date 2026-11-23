import SwiftUI
import MapboxMaps
import CoreLocation

struct OfflineNavigationAreas: View {
    let token: String
    let style: GalaxyBasemap
    @ObservedObject var navigation: NavigationModel
    @State private var aroundDestination = false
    @State private var width = 10
    @State private var areas: [String] = []
    @State private var download: Cancelable?
    @State private var status = ""
    @State private var progress = 0.0
    @State private var operation: UUID?
    @State private var removal: String?

    private var center: CLLocationCoordinate2D? {
        aroundDestination ? navigation.destination?.coordinate : navigation.goodLocation?.coordinate
    }
    var body: some View {
        Form {
            Section {
                Picker("Area center", selection: $aroundDestination) {
                    Text("Current location").tag(false)
                    Text("Selected destination").tag(true)
                }
                Picker("Area width", selection: $width) {
                    ForEach([5, 10, 25, 50], id: \.self) { Text("\($0) km").tag($0) }
                }
                if operation == nil {
                    Button("Download area") { start() }.disabled(center == nil)
                } else {
                    ProgressView(value: progress)
                    Button("Cancel download") { cancel() }
                }
                if !status.isEmpty { Text(status).font(.footnote) }
            } header: { Text("Save an area") } footer: {
                Text("Downloads \(style.rawValue) map detail and Mapbox routing data around the center. Keep this screen open until the download finishes. Choose a destination on the map or allow precise location.")
            }
            Section("Saved areas") {
                if areas.isEmpty { Text("No saved areas").foregroundStyle(.secondary) }
                ForEach(areas, id: \.self) { id in
                    HStack {
                        Text(String(id.dropFirst(7)))
                        Spacer()
                        Button(role: .destructive) { removal = id } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove saved area")
                    }
                }
            }
        }.navigationTitle("Offline areas")
        .onAppear { reload(); navigation.requestLocation() }
        .onDisappear { cancel() }
        .alert("Remove saved area?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove", role: .destructive) {
                if let removal {
                    TileStore.default.removeRegion(forId: removal) { result in
                        DispatchQueue.main.async {
                            if case let .failure(error) = result { status = error.localizedDescription }
                            reload()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func reload() {
        TileStore.default.allTileRegions { result in
            DispatchQueue.main.async {
                switch result {
                case let .success(regions): areas = regions.map(\.id).filter { $0.hasPrefix("Galaxy ") }.sorted()
                case let .failure(error): status = error.localizedDescription
                }
            }
        }
    }
    private func cancel() {
        guard operation != nil else { return }
        operation = nil
        download?.cancel()
        download = nil
        status = "Download canceled."
    }
    private func start() {
        guard let center, operation == nil else { return }
        let dy = Double(width) / 222
        let dx = dy / max(0.01, cos(center.latitude * .pi / 180))
        guard abs(center.latitude) + dy < 85, abs(center.longitude) + dx < 180 else {
            status = "Choose a smaller area away from the poles or the date line."
            return
        }
        let ring = [(-dy,-dx), (-dy,dx), (dy,dx), (dy,-dx), (-dy,-dx)].map {
            CLLocationCoordinate2D(latitude: center.latitude + $0.0, longitude: center.longitude + $0.1)
        }
        let provider = GalaxyNavigationSDK.provider(token: token)
        let manager = OfflineManager()
        let descriptor = manager.createTilesetDescriptor(for: .init(styleURI: style.uri, zoomRange: 0...16, tilesets: nil))
        let id = String(format: "Galaxy %.3f, %.3f · %d km · %@", locale: Locale(identifier: "en_US_POSIX"),
                        center.latitude, center.longitude, width, style.rawValue)
        guard let tiles = TileRegionLoadOptions(geometry: .polygon(Polygon([ring])),
            descriptors: [descriptor, provider.getLatestNavigationTilesetDescriptor()], metadata: ["name": id], acceptExpired: false),
              let pack = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally, metadata: nil) else { return }
        let taskID = UUID()
        operation = taskID
        progress = 0
        status = "Downloading map style…"
        download = manager.loadStylePack(for: style.uri, loadOptions: pack) { _ in } completion: { result in
            DispatchQueue.main.async {
                guard operation == taskID else { return }
                if case let .failure(error) = result {
                    status = error.localizedDescription; operation = nil; download = nil
                    return
                }
                status = "Downloading map and routing data…"
                download = TileStore.default.loadTileRegion(forId: id, loadOptions: tiles) { state in
                    DispatchQueue.main.async {
                        guard operation == taskID else { return }
                        progress = Double(state.completedResourceCount) / Double(max(1, state.requiredResourceCount))
                    }
                } completion: { result in
                    DispatchQueue.main.async {
                        guard operation == taskID else { return }
                        switch result {
                        case .success: status = "Area saved."
                        case let .failure(error): status = error.localizedDescription
                        }
                        operation = nil; download = nil; reload()
                    }
                }
            }
        }
    }
}
