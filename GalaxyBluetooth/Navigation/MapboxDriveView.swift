import SwiftUI
import MapKit
import MapboxMaps

enum NavigationMapPreference {
    static let enabledKey = "navigation.mapboxEnabled"
    static let tokenKey = "navigation.mapboxPublicToken"
    static let poiKey = "navigation.mapboxPointLabels"
    static let placesKey = "navigation.mapboxPlaceLabels"
    static let trafficKey = "navigation.mapboxTraffic"
    static var activeToken: String? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) as? Bool != false,
              let token = defaults.string(forKey: tokenKey), token.hasPrefix("pk.") else { return nil }
        return token
    }
}

private enum PointLabels: String {
    case automatic, browsing, always, off

    func visible(driving: Bool) -> Bool {
        self != .off && (self != .browsing || !driving)
    }
}

struct NavigationMapSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""
    @AppStorage(NavigationMapPreference.enabledKey) private var enabled = true
    @State private var entry = ""
    @AppStorage(NavigationMapPreference.poiKey) private var savedLabels = PointLabels.always
    @AppStorage(NavigationMapPreference.placesKey) private var savedPlaces = true
    @AppStorage(NavigationMapPreference.trafficKey) private var savedTraffic = false
    @State private var labels = PointLabels.always
    @State private var places = true
    @State private var traffic = false
    private var trimmed: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Mapbox public token (pk.…)", text: $entry)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use Mapbox 3D") {
                        token = trimmed
                        savedLabels = labels
                        savedPlaces = places
                        savedTraffic = traffic
                        enabled = true
                        dismiss()
                    }.disabled(!trimmed.hasPrefix("pk.") || trimmed.count < 4)
                    Button("Use Apple Maps") { enabled = false; dismiss() }
                } footer: {
                    Text("Mapbox displays the iPhone navigation map and calculates iPhone-guided routes. Comma-guided trips use the route from your comma.")
                }
                Section {
                    Picker("Stores & points of interest", selection: $labels) {
                        Text("Always").tag(PointLabels.always)
                        Text("Fewer during guidance").tag(PointLabels.automatic)
                        Text("Only while browsing").tag(PointLabels.browsing)
                        Text("Off").tag(PointLabels.off)
                    }
                    Toggle("City & neighborhood names", isOn: $places)
                    Toggle("Traffic congestion", isOn: $traffic)
                } header: { Text("Mapbox display") } footer: {
                    Text("Traffic shows reported slowdowns from amber to dark red. Choose Use Mapbox 3D to save.")
                }
            }
            .navigationTitle("Navigation map").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.onAppear { entry = token; labels = savedLabels; places = savedPlaces; traffic = savedTraffic }
    }
}

/// Uses the same navigation state and controls as the standard iPhone map.
struct DrivePositionMarker: View {
    static let diameter: CGFloat = 32
    static let barClearance: CGFloat = 8
    let following: Bool
    let comma: Bool

    var body: some View {
        Image(systemName: following ? "location.north.fill" : "circle.fill")
            .font(.callout.bold()).foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter).background(StarPilotTheme.accent, in: Circle())
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .accessibilityLabel(comma ? "Comma location" : "Your location")
    }
}

struct CarDisplayMapOptions: Equatable {
    let overview: Bool
    let zoomFactor: Double
    let dashboard: Bool
}

struct MapboxDriveMap: View {
    private static let destinationIcon: UIImage = {
        let palette = UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        let symbol = UIImage(systemName: "mappin.circle.fill", withConfiguration: palette)?
            .withRenderingMode(.alwaysOriginal)
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { _ in
            symbol?.draw(in: CGRect(origin: .zero, size: size))
        }
    }()
    @ObservedObject var navigation: NavigationModel
    @AppStorage(NavigationMapPreference.poiKey) private var labels = PointLabels.always
    @AppStorage(NavigationMapPreference.placesKey) private var showPlaces = true
    @AppStorage(NavigationMapPreference.trafficKey) private var showTraffic = false
    let carDisplay: CarDisplayMapOptions?
    let headerBottom: CGFloat
    let tripFrame: CGRect
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport
    @State private var routeShape: LineString?
    @State private var routePoints: [RoutePoint] = []
    @State private var lastCommaFix: CLLocation?
    @State private var commaSpeed = 0.0
    @State private var cameraFix: CLLocation?
    @State private var cameraBearing = 0.0
    @State private var cameraZoom = 16.8
    @State private var cameraPitch = 68.0

    private var following: Bool { carDisplay.map { !$0.overview } ?? navigation.followsUser }
    private var anchored: Bool { driving && following && cameraFix != nil }

    init(navigation: NavigationModel, token: String, tripFrame: CGRect, headerBottom: CGFloat = 0, carDisplay: CarDisplayMapOptions? = nil) {
        self.navigation = navigation
        self.carDisplay = carDisplay
        self.headerBottom = headerBottom
        self.tripFrame = tripFrame
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
            let top = min(driving ? 190.0 : 90.0, geometry.size.height * 0.32)
            let bounds = geometry.frame(in: .global)
            let phoneInset = driving && !tripFrame.isEmpty ? min(bounds.height, max(0, bounds.maxY - tripFrame.minY)) : 0
            let panel: CGFloat = carDisplay == nil ? phoneInset : min(65, geometry.size.height * 0.24)
            let headerInset = max(8, headerBottom - bounds.minY + 2)
            let anchor = CGPoint(
                x: carDisplay == nil ? (tripFrame.isEmpty ? bounds.width / 2 : min(bounds.width * 0.9, max(bounds.width * 0.1, tripFrame.midX - bounds.minX))) :
                    bounds.width / 2 + (geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing) / 2,
                y: max(bounds.height * 0.35, bounds.height - panel - (carDisplay == nil ? DrivePositionMarker.barClearance + DrivePositionMarker.diameter / 2 : 18)))
            let dx = 2 * anchor.x - bounds.width, dy = 2 * anchor.y - bounds.height
            let padding = driving ? EdgeInsets(top: max(0, dy), leading: max(0, dx), bottom: max(0, -dy), trailing: max(0, -dx))
                                  : EdgeInsets(top: top, leading: 0, bottom: panel, trailing: 0)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                MapboxMaps.Map(viewport: $viewport) {
                    if showTraffic {
                        VectorSource(id: "galaxy-traffic").url("mapbox://mapbox.mapbox-traffic-v1")
                        LineLayer(id: "galaxy-congestion", source: "galaxy-traffic")
                            .sourceLayer("traffic").slot(.middle)
                            .lineWidth(2.5).lineOffset(5.5).lineCap(.round).lineEmissiveStrength(1)
                            .lineColor(Exp(.match) {
                                Exp(.get) { "congestion" }
                                "moderate"; "#FFB020"
                                "heavy"; "#EF493D"
                                "severe"; "#AD1834"
                                "rgba(0,0,0,0)"
                            })
                    }
                    if let routeShape {
                        GeoJSONSource(id: "galaxy-route").data(.geometry(.lineString(routeShape)))
                        LineLayer(id: "galaxy-selected-route", source: "galaxy-route")
                            .slot(.middle).lineCap(.round).lineJoin(.round)
                            .lineOcclusionOpacity(0)
                            .lineColor(StarPilotTheme.routePurple).lineWidth(7)
                            .lineBorderColor(UIColor(red: 0.27, green: 0.08, blue: 0.43, alpha: 1))
                            .lineBorderWidth(1).lineEmissiveStrength(1)
                    }
                    if let destination = navigation.destination {
                        GeoJSONSource(id: "galaxy-destination")
                            .data(.feature(destinationFeature(destination)))
                        StyleImage(id: "galaxy-destination-pin", image: Self.destinationIcon)
                        SymbolLayer(id: "galaxy-destination-symbol", source: "galaxy-destination")
                            .slot(.middle).iconImage("galaxy-destination-pin").iconAnchor(.bottom)
                            .iconAllowOverlap(true).iconIgnorePlacement(true).iconOcclusionOpacity(0)
                    }
                    if !driving, let start = navigation.plannedStart {
                        MapViewAnnotation(coordinate: start.coordinate) {
                            Image(systemName: "flag.circle.fill").font(.title)
                                .foregroundStyle(.white, StarPilotTheme.accent).accessibilityLabel("Starting point: \(start.name)")
                        }
                    }
                    if !(driving && following && carDisplay == nil) && !anchored, let point = position(at: clock.date) {
                        MapViewAnnotation(coordinate: aligned(point)) {
                            DrivePositionMarker(following: false, comma: commaTrip)
                        }
                    }
                }
                .mapStyle(.standard(lightPreset: colorScheme == .dark ? .night : .day,
                                    showPointOfInterestLabels: labels.visible(driving: driving),
                                    showPlaceLabels: showPlaces,
                                    densityPointOfInterestLabels: labels == .automatic && driving ? 1 : 3))
                .usesSafeAreaInsetsAsPadding(!anchored)
                .ornamentOptions(mapOrnaments(headerInset: headerInset, panel: panel))
                .onMapLoadingError {
                    if $0.type == .style {
                        navigation.notice = "Mapbox couldn’t load. Check your internet connection and public token in Navigation map settings."
                    }
                }
                .overlay {
                    if carDisplay != nil, anchored, position(at: clock.date) != nil {
                        DrivePositionMarker(following: true, comma: commaTrip)
                            .position(anchor)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onChange(of: viewport.isIdle) { _, idle in
                if idle && carDisplay == nil { navigation.followsUser = false }
            }
            .onChange(of: route.map { ObjectIdentifier($0) }, initial: true) { _, _ in
                routeShape = route.flatMap { line in
                    guard line.pointCount >= 2 else { return nil }
                    let points = line.points()
                    return LineString((0..<line.pointCount).map { points[$0].coordinate })
                }
                routePoints = routeShape?.coordinates.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) } ?? []
                if driving { cameraFix = nil }
                if !driving && navigation.destination != nil { preview(top: top, bottom: panel, padding: padding) }
                else if following && position(at: .now) != nil { follow(padding: padding) }
                else if following || carDisplay?.overview == true { overview(top: top, bottom: panel) }
            }
            .onChange(of: navigation.destination?.id) { _, _ in preview(top: top, bottom: panel, padding: padding) }
            .onChange(of: driving) { _, _ in cameraFix = nil; follow(padding: padding) }
            .onChange(of: navigation.overviewRevision) { _, _ in
                if carDisplay == nil { overview(top: top, bottom: panel) }
            }
            .onChange(of: carDisplay) { _, options in
                guard let options else { return }
                if options.overview { overview(top: top, bottom: panel) }
                else { follow(padding: padding, layoutChanged: true) }
            }
            .onChange(of: following) { _, _ in cameraFix = nil; follow(padding: padding) }
            .onChange(of: commaTrip ? navigation.commaPositionSampleDate : navigation.location?.timestamp) { _, _ in
                if commaTrip { updateCommaSpeed() }
                if driving || navigation.destination == nil { follow(padding: padding) }
            }
            .onChange(of: navigation.positionDisplayGeneration) { _, _ in lastCommaFix = nil; commaSpeed = 0; cameraFix = nil }
            .onChange(of: navigation.commaFeedReady) { _, ready in
                if !ready && commaTrip { cameraFix = nil }
                follow(padding: padding)
            }
            .onChange(of: padding) { _, _ in follow(padding: padding, layoutChanged: true) }
        }
    }

    private func mapOrnaments(headerInset: CGFloat, panel: CGFloat) -> OrnamentOptions {
        var options = OrnamentOptions()
        if let carDisplay {
            options.scaleBar.visibility = .hidden
            // Leave the screen edges for CarPlay’s dock and zoom buttons.
            let inset: CGFloat = carDisplay.dashboard ? 8 : 52
            options.attributionButton.margins = CGPoint(x: inset, y: panel + 6)
            options.logo.position = .bottomTrailing
            options.logo.margins = CGPoint(x: inset + 28, y: panel + 6)
        } else {
            options.scaleBar.margins = CGPoint(x: 12, y: headerInset)
            options.compass.margins = CGPoint(x: 12, y: headerInset)
            options.logo.margins = CGPoint(x: 8, y: panel + 6)
            options.attributionButton.margins = CGPoint(x: 8, y: panel + 6)
        }
        return options
    }

    private func destinationFeature(_ destination: NavigationPlace) -> Feature {
        var feature = Feature(geometry: .point(Point(destination.coordinate)))
        feature.properties = ["name": .string(destination.name)]
        return feature
    }

    private func aligned(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard driving else { return coordinate }
        return NavigationMapMotion.alignedCoordinate(coordinate, route: routePoints)
    }

    private func follow(padding: EdgeInsets, layoutChanged: Bool = false) {
        guard following, driving || navigation.destination == nil,
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
        let targetPitch = driving ? navigation.followPitch(cruising: 68, speed: speed) : 48
        cameraPitch += (targetPitch - cameraPitch) * (continuous ? 1 - exp(-dt / 1.2) : 1)
        let accepted = continuous && !moving ? previous?.coordinate ?? point : point
        let center = aligned(accepted)
        cameraFix = CLLocation(coordinate: accepted, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: stamp)
        let camera = Viewport.camera(center: center, zoom: CGFloat(cameraZoom - log2(carDisplay?.zoomFactor ?? 1)), bearing: cameraBearing,
                                     pitch: CGFloat(cameraPitch))
            .padding(padding)
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
        guard let routeShape else { return }
        viewport = .overview(geometry: routeShape,
                             geometryPadding: .init(top: top + 8, leading: 24, bottom: bottom + 16, trailing: 24))
    }

    private func preview(top: CGFloat, bottom: CGFloat, padding: EdgeInsets) {
        guard !driving else { return }
        if routeShape != nil { overview(top: top, bottom: bottom) }
        else if let destination = navigation.destination {
            viewport = .camera(center: destination.coordinate, zoom: 16.8, pitch: 50)
        } else { follow(padding: padding) }
    }
}
