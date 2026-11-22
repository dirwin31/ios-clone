import SwiftUI
import MapKit
import MapboxMaps

/// A separate display of the comma route. Opening or closing it never starts a trip.
struct MapboxDriveView: View {
    @ObservedObject var navigation: NavigationModel
    let connection: CommaConnection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigation.mapboxPublicToken") private var savedToken = ""
    @State private var entry = ""
    @State private var activeToken: String?

    var body: some View {
        NavigationStack {
            Group {
                if activeToken != nil {
                    MapboxDriveMap(navigation: navigation, connection: connection)
                } else {
                    Form {
                        Section {
                            SecureField("pk.…", text: $entry)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Open 3D map") {
                                let token = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                                savedToken = token
                                activate(token)
                            }.disabled(!entry.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pk."))
                        } header: {
                            Text("Mapbox public access token")
                        } footer: {
                            Text("Map tiles use your Mapbox account. Galaxy saves this public token on this device.")
                        }
                    }
                }
            }
            .navigationTitle("3D Drive").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if activeToken != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Change token", systemImage: "key") {
                            activeToken = nil
                            entry = ""
                        }
                    }
                }
            }
        }
        .onAppear { if savedToken.hasPrefix("pk.") { activate(savedToken) } }
    }

    private func activate(_ token: String) {
        MapboxOptions.accessToken = token
        activeToken = token
    }
}

private struct MapboxDriveMap: View {
    @ObservedObject var navigation: NavigationModel
    let connection: CommaConnection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 43.6426, longitude: -79.3871),
        zoom: 15.3, bearing: 65, pitch: 60)
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var following = true
    @State private var loadFailed = false

    private var driving: Bool { navigation.navigating && navigation.usingComma }
    private var route: MKPolyline? { driving ? navigation.commaPolyline : nil }
    private func hasPosition(at date: Date) -> Bool {
        driving && navigation.commaFeedReady && navigation.commaPosition != nil &&
            date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4
    }

    var body: some View {
        VStack(spacing: 0) {
            if loadFailed {
                Text("Couldn’t load the Mapbox style. Check your connection and public token.")
                    .font(.callout).padding(8)
            }
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let fresh = hasPosition(at: clock.date)
                VStack(spacing: 0) {
                    if driving {
                        VStack(alignment: .leading, spacing: 4) {
                            if fresh {
                                Text(distance(navigation.distanceToTurn)).font(.title.bold())
                                Text(navigation.instruction).font(.headline)
                            } else { Text("Waiting for comma guidance").font(.headline) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    MapboxMaps.Map(viewport: $viewport) {
                        if coordinates.count >= 2 {
                            PolylineAnnotation(lineCoordinates: coordinates)
                                .lineColor(UIColor.systemCyan).lineWidth(6)
                        }
                        if fresh, let point = navigation.commaPosition {
                            MapViewAnnotation(coordinate: point) {
                                Circle().fill(.blue).frame(width: 26, height: 26)
                                    .overlay { Circle().stroke(.white, lineWidth: 2) }
                                    .overlay {
                                        if following {
                                            Image(systemName: "location.north.fill")
                                                .font(.caption.bold()).foregroundStyle(.white)
                                        }
                                    }
                                    .accessibilityLabel("Comma location")
                            }
                        }
                    }
                    .mapStyle(.standard(lightPreset: colorScheme == .dark ? .night : .day))
                    .onMapLoadingError { if $0.type == .style { loadFailed = true } }
                    .onStyleLoaded { _ in loadFailed = false }
                    .onChange(of: viewport.isIdle) { _, idle in if idle { following = false } }
                    if driving {
                        HStack {
                            if fresh {
                                VStack(alignment: .leading) {
                                    Text(Date.now.addingTimeInterval(navigation.remainingTime), style: .time)
                                        .font(.headline)
                                    Text("Arrival").font(.caption)
                                }
                                Text(NavigationDuration.text(navigation.remainingTime))
                                Text(distance(navigation.remainingDistance))
                            }
                            Spacer()
                            Button("Route overview", systemImage: "arrow.up.left.and.arrow.down.right") {
                                following = false
                                showRoute()
                            }.disabled(coordinates.count < 2)
                            Button("Follow comma", systemImage: "location.fill") {
                                following = true
                                follow()
                            }.disabled(!fresh)
                            Button("End", role: .destructive) {
                                Task { await navigation.end(connection: connection) }
                            }.disabled(navigation.busy)
                        }.padding().labelStyle(.iconOnly)
                    } else {
                        Text("Explore the map, or start a comma route for live guidance.")
                            .font(.callout).padding()
                    }
                }
            }
        }
        .onChange(of: route.map { ObjectIdentifier($0) }, initial: true) { _, _ in
            coordinates = route.map { line in
                let points = line.points()
                return (0..<line.pointCount).map { points[$0].coordinate }
            } ?? []
            if following {
                if hasPosition(at: .now) { follow() } else { showRoute() }
            }
        }
        .onChange(of: navigation.commaPositionSampleDate, initial: true) { _, _ in follow() }
        .onChange(of: navigation.commaFeedReady) { _, _ in follow() }
    }

    private func follow() {
        guard following, hasPosition(at: .now), let point = navigation.commaPosition else { return }
        let camera = Viewport.camera(center: point, zoom: 16, bearing: navigation.commaHeading, pitch: 60)
            .padding(.top, 100)
        if reduceMotion { viewport = camera }
        else { withViewportAnimation(.easeInOut(duration: 0.35)) { viewport = camera } }
    }

    private func showRoute() {
        guard coordinates.count >= 2 else { return }
        viewport = .overview(geometry: LineString(coordinates),
                             geometryPadding: .init(top: 28, leading: 28, bottom: 28, trailing: 28))
    }

    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
