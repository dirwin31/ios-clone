import SwiftUI
import MapKit
import MapboxMaps

enum NavigationMapPreference {
    static let enabledKey = "navigation.mapboxEnabled"
    static let tokenKey = "navigation.mapboxPublicToken"
}

struct NavigationMapSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""
    @AppStorage(NavigationMapPreference.enabledKey) private var enabled = true
    @State private var entry = ""
    private var trimmed: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Mapbox public token (pk.…)", text: $entry)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use Mapbox 3D") {
                        token = trimmed
                        enabled = true
                        dismiss()
                    }.disabled(!trimmed.hasPrefix("pk.") || trimmed.count < 4)
                    Button("Use Apple Maps") { enabled = false; dismiss() }
                } footer: {
                    Text("Mapbox appears in Navigation while browsing and during comma guidance. Apple Maps handles destination previews and iPhone-guided routes.")
                }
            }
            .navigationTitle("Navigation map").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.onAppear { entry = token }
    }
}

/// Uses the same navigation state and controls as the standard iPhone map.
struct MapboxDriveMap: View {
    @ObservedObject var navigation: NavigationModel
    let bottomInset: CGFloat
    let onStyleFailure: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport
    @State private var coordinates: [CLLocationCoordinate2D] = []

    init(navigation: NavigationModel, token: String, bottomInset: CGFloat, onStyleFailure: @escaping () -> Void) {
        self.navigation = navigation
        self.bottomInset = bottomInset
        self.onStyleFailure = onStyleFailure
        if MapboxOptions.accessToken != token { MapboxOptions.accessToken = token }
        let center = navigation.usingComma ? navigation.commaPosition : navigation.location?.coordinate
        _viewport = State(initialValue: .camera(center: center, zoom: center == nil ? 1 : 15, pitch: 55))
    }

    private var driving: Bool { navigation.navigating && navigation.usingComma }
    private var route: MKPolyline? { driving ? navigation.commaPolyline : nil }

    private func position(at date: Date) -> CLLocationCoordinate2D? {
        if driving {
            guard navigation.commaFeedReady, date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4 else { return nil }
            return navigation.commaPosition
        }
        return navigation.goodLocation?.coordinate
    }

    var body: some View {
        GeometryReader { geometry in
            let panel = driving ? min(bottomInset + 16, geometry.size.height * 0.45) : 0
            let top = min(driving ? 190.0 : 90.0, geometry.size.height * 0.32)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                MapboxMaps.Map(viewport: $viewport) {
                    if coordinates.count >= 2 {
                        PolylineAnnotation(lineCoordinates: coordinates)
                            .lineColor(UIColor.systemCyan).lineWidth(6)
                    }
                    if let point = position(at: clock.date) {
                        MapViewAnnotation(coordinate: point) {
                            Image(systemName: driving && navigation.followsUser ? "location.north.fill" : "circle.fill")
                                .font(.callout.bold()).foregroundStyle(.white)
                                .frame(width: 32, height: 32).background(.blue, in: Circle())
                                .overlay { Circle().stroke(.white, lineWidth: 2) }
                                .accessibilityLabel(driving ? "Comma location" : "Your location")
                        }
                    }
                }
                .mapStyle(.standard(lightPreset: colorScheme == .dark ? .night : .day))
                .ornamentOptions(.init(logo: .init(margins: .init(x: 8, y: panel + 6)),
                                       attributionButton: .init(margins: .init(x: 8, y: panel + 6))))
                .onMapLoadingError { if $0.type == .style { onStyleFailure() } }
            }
            .onChange(of: viewport.isIdle) { _, idle in if idle { navigation.followsUser = false } }
            .onChange(of: route.map { ObjectIdentifier($0) }, initial: true) { _, _ in
                coordinates = route.map { line in
                    let points = line.points()
                    return (0..<line.pointCount).map { points[$0].coordinate }
                } ?? []
                if navigation.followsUser && position(at: .now) != nil { follow(top: top, bottom: panel) }
                else if navigation.followsUser { overview(top: top, bottom: panel) }
            }
            .onChange(of: navigation.overviewRevision) { _, _ in overview(top: top, bottom: panel) }
            .onChange(of: navigation.followsUser) { _, _ in follow(top: top, bottom: panel) }
            .onChange(of: driving ? navigation.commaPositionSampleDate : navigation.location?.timestamp) { _, _ in follow(top: top, bottom: panel) }
            .onChange(of: navigation.commaFeedReady) { _, _ in follow(top: top, bottom: panel) }
            .onChange(of: panel) { _, _ in follow(top: top, bottom: panel) }
        }
    }

    private func follow(top: CGFloat, bottom: CGFloat) {
        guard navigation.followsUser, let point = position(at: .now) else { return }
        let camera = Viewport.camera(center: point, zoom: driving ? 16 : 15,
                                     bearing: driving ? navigation.commaHeading : 0, pitch: driving ? 60 : 48)
            .padding(.init(top: top, leading: 0, bottom: bottom, trailing: 0))
        if reduceMotion { viewport = camera }
        else { withViewportAnimation(.easeInOut(duration: 0.35)) { viewport = camera } }
    }

    private func overview(top: CGFloat, bottom: CGFloat) {
        guard coordinates.count >= 2 else { return }
        viewport = .overview(geometry: LineString(coordinates),
                             geometryPadding: .init(top: top + 8, leading: 24, bottom: bottom + 16, trailing: 24))
    }
}
