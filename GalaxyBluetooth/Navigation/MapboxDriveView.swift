import SwiftUI
import MapKit
import MapboxMaps

enum NavigationMapPreference {
    static let enabledKey = "navigation.mapboxEnabled"
    static let tokenKey = "navigation.mapboxPublicToken"
    static var activeToken: String? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) as? Bool != false,
              let token = defaults.string(forKey: tokenKey), token.hasPrefix("pk.") else { return nil }
        return token
    }
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
                    Text("Mapbox displays the iPhone navigation map and calculates iPhone-guided routes. Comma-guided trips use the route from your comma.")
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var lastCommaFix: CLLocation?
    @State private var commaSpeed = 0.0
    @State private var cameraFix: CLLocation?
    @State private var cameraBearing = 0.0
    @State private var cameraZoom = 16.8

    private var anchored: Bool { driving && navigation.followsUser && cameraFix != nil }

    init(navigation: NavigationModel, token: String, bottomInset: CGFloat) {
        self.navigation = navigation
        self.bottomInset = bottomInset
        if MapboxOptions.accessToken != token { MapboxOptions.accessToken = token }
        let center = navigation.usingComma ? navigation.commaPosition : navigation.location?.coordinate
        _viewport = State(initialValue: .camera(center: center, zoom: center == nil ? 1 : 16.8, pitch: 55))
    }

    private var driving: Bool { navigation.navigating }
    private var commaTrip: Bool { driving && navigation.usingComma }
    private var route: MKPolyline? {
        if commaTrip { return navigation.commaPolyline }
        return navigation.sendToComma && !driving ? nil : navigation.route?.polyline
    }

    private func position(at date: Date) -> CLLocationCoordinate2D? {
        if commaTrip {
            guard navigation.commaFeedReady, date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4 else { return nil }
            return navigation.commaPosition
        }
        return navigation.goodLocation?.coordinate
    }

    var body: some View {
        GeometryReader { geometry in
            let panel = commaTrip ? min(bottomInset + 16, geometry.size.height * 0.45) : 0
            let top = min(driving ? 190.0 : 90.0, geometry.size.height * 0.32)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                MapboxMaps.Map(viewport: $viewport) {
                    if let destination = navigation.destination {
                        MapViewAnnotation(coordinate: destination.coordinate) {
                            Image(systemName: "mappin.circle.fill").font(.title)
                                .foregroundStyle(.white, .red).accessibilityLabel(destination.name)
                        }
                    }
                    if coordinates.count >= 2 {
                        PolylineAnnotation(lineCoordinates: coordinates)
                            .lineColor(StarPilotTheme.uiAccent).lineWidth(6)
                    }
                    if !driving, let start = navigation.plannedStart {
                        MapViewAnnotation(coordinate: start.coordinate) {
                            Image(systemName: "flag.circle.fill").font(.title)
                                .foregroundStyle(.white, StarPilotTheme.accent).accessibilityLabel("Starting point: \(start.name)")
                        }
                    }
                    if !anchored, let point = position(at: clock.date) {
                        MapViewAnnotation(coordinate: point) {
                            positionMarker(following: false)
                        }
                    }
                }
                .mapStyle(.standard(lightPreset: colorScheme == .dark ? .night : .day))
                .usesSafeAreaInsetsAsPadding(!anchored)
                .ornamentOptions(.init(logo: .init(margins: .init(x: 8, y: panel + 6)),
                                       attributionButton: .init(margins: .init(x: 8, y: panel + 6))))
                .onMapLoadingError {
                    if $0.type == .style {
                        navigation.notice = "Mapbox couldn’t load. Check your internet connection and public token in Navigation map settings."
                    }
                }
                .overlay {
                    if anchored, position(at: clock.date) != nil {
                        positionMarker(following: true)
                            .padding(.top, top).padding(.bottom, panel)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onChange(of: viewport.isIdle) { _, idle in if idle { navigation.followsUser = false } }
            .onChange(of: route.map { ObjectIdentifier($0) }, initial: true) { _, _ in
                coordinates = route.map { line in
                    let points = line.points()
                    return (0..<line.pointCount).map { points[$0].coordinate }
                } ?? []
                if !driving && navigation.destination != nil { preview(top: top, bottom: panel) }
                else if navigation.followsUser && position(at: .now) != nil { follow(top: top, bottom: panel) }
                else if navigation.followsUser { overview(top: top, bottom: panel) }
            }
            .onChange(of: navigation.destination?.id) { _, _ in preview(top: top, bottom: panel) }
            .onChange(of: driving) { _, _ in cameraFix = nil; follow(top: top, bottom: panel) }
            .onChange(of: navigation.overviewRevision) { _, _ in overview(top: top, bottom: panel) }
            .onChange(of: navigation.followsUser) { _, _ in cameraFix = nil; follow(top: top, bottom: panel) }
            .onChange(of: commaTrip ? navigation.commaPositionSampleDate : navigation.location?.timestamp) { _, _ in
                if commaTrip { updateCommaSpeed() }
                if driving || navigation.destination == nil { follow(top: top, bottom: panel) }
            }
            .onChange(of: navigation.positionDisplayGeneration) { _, _ in lastCommaFix = nil; commaSpeed = 0; cameraFix = nil }
            .onChange(of: navigation.commaFeedReady) { _, ready in
                if !ready && commaTrip { cameraFix = nil }
                follow(top: top, bottom: panel)
            }
            .onChange(of: panel) { _, _ in follow(top: top, bottom: panel, layoutChanged: true) }
            .onChange(of: top) { _, _ in follow(top: top, bottom: panel, layoutChanged: true) }
        }
    }

    private func positionMarker(following: Bool) -> some View {
        Image(systemName: following ? "location.north.fill" : "circle.fill")
            .font(.callout.bold()).foregroundStyle(.white)
            .frame(width: 32, height: 32).background(StarPilotTheme.accent, in: Circle())
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .accessibilityLabel(commaTrip ? "Comma location" : "Your location")
    }

    private func follow(top: CGFloat, bottom: CGFloat, layoutChanged: Bool = false) {
        guard navigation.followsUser, driving || navigation.destination == nil,
              let point = position(at: .now), let stamp = commaTrip
                ? navigation.commaPositionSampleDate : navigation.location?.timestamp else { return }
        let previous = cameraFix
        let dt = previous.map { stamp.timeIntervalSince($0.timestamp) } ?? 0
        guard previous == nil || dt > 0 || layoutChanged else { return }
        let fix = CLLocation(coordinate: point, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: stamp)
        let displacement = previous.map { fix.distance(from: $0) } ?? 0
        let continuous = previous != nil && dt >= 0 && dt <= 4 && displacement < 250
        let speed = commaTrip ? commaSpeed : navigation.goodLocation?.speed ?? 0
        let distance = NavigationMapMotion.cameraDistance(speed: speed, distanceToTurn: navigation.distanceToTurn)
        // Restrict the guide camera to street-level detail while keeping lookahead on faster roads.
        let zoom = driving ? 17.6 - 0.8 * log2(distance / 1200) : 16.8
        let measuredBearing = commaTrip ? navigation.commaHeading : navigation.location?.course ?? -1
        let validBearing = measuredBearing.isFinite && (0..<360).contains(measuredBearing)
        let moving = speed >= 1.2 || displacement >= 6
        if validBearing && (!continuous || moving) {
            cameraBearing = NavigationMapMotion.heading(from: cameraBearing, to: measuredBearing,
                fraction: continuous ? 1 - exp(-dt / 0.5) : 1)
        }
        cameraZoom += (zoom - cameraZoom) * (continuous ? 1 - exp(-dt / 2) : 1)
        let center = continuous && !moving ? previous?.coordinate ?? point : point
        cameraFix = CLLocation(coordinate: center, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: stamp)
        let camera = Viewport.camera(center: center, zoom: CGFloat(cameraZoom), bearing: cameraBearing,
                                     pitch: driving ? 60 : 48)
            .padding(.init(top: top, leading: 0, bottom: bottom, trailing: 0))
        if reduceMotion || !continuous || layoutChanged { viewport = camera }
        else { withViewportAnimation(.linear(duration: min(2.5, max(0.1, dt)))) { viewport = camera } }
    }

    private func updateCommaSpeed() {
        guard let point = position(at: .now) else { lastCommaFix = nil; commaSpeed = 0; return }
        let fix = CLLocation(coordinate: point, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                             timestamp: navigation.commaPositionSampleDate)
        defer { lastCommaFix = fix }
        guard let previous = lastCommaFix else { return }
        let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0, dt <= 5 else { commaSpeed = 0; return }
        let measured = fix.distance(from: previous) / dt
        if measured <= 55 { commaSpeed += (measured - commaSpeed) * (1 - exp(-dt / 3)) }
    }

    private func overview(top: CGFloat, bottom: CGFloat) {
        guard coordinates.count >= 2 else { return }
        viewport = .overview(geometry: LineString(coordinates),
                             geometryPadding: .init(top: top + 8, leading: 24, bottom: bottom + 16, trailing: 24))
    }

    private func preview(top: CGFloat, bottom: CGFloat) {
        guard !driving else { return }
        if coordinates.count >= 2 { overview(top: top, bottom: bottom) }
        else if let destination = navigation.destination {
            viewport = .camera(center: destination.coordinate, zoom: 16.8, pitch: 50)
        } else { follow(top: top, bottom: bottom) }
    }
}
