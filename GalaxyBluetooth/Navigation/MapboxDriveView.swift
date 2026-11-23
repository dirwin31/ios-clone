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


enum GalaxyAppleMap: String, CaseIterable {
    case streets = "Street map", hybrid = "Satellite with labels", imagery = "Satellite imagery"
    var style: MapKit.MapStyle {
        switch self {
        case .streets: .standard(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .imagery: .imagery(elevation: .realistic)
        }
    }
    var configuration: MKMapConfiguration {
        switch self {
        case .streets: MKStandardMapConfiguration(elevationStyle: .realistic)
        case .hybrid: MKHybridMapConfiguration(elevationStyle: .realistic)
        case .imagery: MKImageryMapConfiguration(elevationStyle: .realistic)
        }
    }
}
enum GalaxyBasemap: String, CaseIterable {
    case standard = "Standard", standardSatellite = "Standard Satellite", streets = "Streets", outdoors = "Outdoors", light = "Light", dark = "Dark", satellite = "Satellite", satelliteStreets = "Satellite Streets"
    var uri: StyleURI {
        switch self {
        case .standard: .standard
        case .standardSatellite: .standardSatellite
        case .streets: .streets
        case .outdoors: .outdoors
        case .light: .light
        case .dark: .dark
        case .satellite: .satellite
        case .satelliteStreets: .satelliteStreets
        }
    }
}

struct NavigationMapSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""
    @AppStorage(NavigationMapPreference.enabledKey) private var enabled = true
    @AppStorage("navigation.appleStyle") private var appleStyle = GalaxyAppleMap.streets
    @AppStorage("navigation.standardOptions") private var styleData = Data()
    @AppStorage("navigation.basemap") private var basemap = GalaxyBasemap.standard
    @AppStorage(NavigationMapPreference.trafficKey) private var traffic = false
    @AppStorage(AppPreference.rememberDestinations) private var remember = true
    @AppStorage(NavigationDistanceUnits.key) private var units = NavigationDistanceUnits.system
    @AppStorage("navigation.phoneRouter") private var router = "Automatic"
    @AppStorage("navigation.offerAlternatives") private var alternatives = true
    @AppStorage("navigation.avoidTolls") private var tolls = false
    @AppStorage("navigation.avoidFerries") private var ferries = false
    @AppStorage("navigation.avoidMotorways") private var motorways = false
    @AppStorage("navigation.cameraPitch") private var pitch = 68.0
    @AppStorage("navigation.zoomAdjustment") private var zoom = 0.0
    @AppStorage("navigation.sdkSpeedLimits") private var speedLimits = true
    @AppStorage("navigation.sdkIntersections") private var intersections = true
    @AppStorage("navigation.sdkDarkTunnels") private var darkTunnels = true
    @AppStorage("navigation.sdkFadeRoute") private var fadeRoute = true
    @State private var entry = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable navigation", isOn: $model.navigationEnabled)
                    Picker("Distance units", selection: $units) {
                        Text("System").tag(NavigationDistanceUnits.system)
                        Text("Metric").tag(NavigationDistanceUnits.metric)
                        Text("Imperial").tag(NavigationDistanceUnits.imperial)
                    }
                    Toggle("Remember destinations", isOn: $remember)
                } header: { Text("Trips") } footer: { Text("Recents are stored on this iPhone.") }
                Section {
                    Picker("Directions provider", selection: $router) {
                        ForEach(["Automatic", "Apple Maps", "Mapbox Driving", "Mapbox Traffic", "Mapbox Navigator"], id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Offer alternative routes", isOn: $alternatives)
                    if router.hasPrefix("Mapbox") || (router == "Automatic" && enabled && token.hasPrefix("pk.")) {
                        Toggle("Avoid toll roads", isOn: $tolls)
                        Toggle("Avoid ferries", isOn: $ferries)
                        Toggle("Avoid motorways", isOn: $motorways)
                    }
                } header: { Text("iPhone directions") } footer: {
                    Text("Automatic follows the selected map. Mapbox Traffic uses reported road speeds when calculating a drive. These preferences apply when you choose iPhone on the destination card. Comma guidance uses your comma’s routing settings and internet connection.")
                }
                Section {
                    Picker("Display map", selection: $enabled) {
                        Text("Apple Maps").tag(false)
                        Text("Mapbox").tag(true)
                    }
                    if !enabled {
                        Picker("Apple map style", selection: $appleStyle) {
                            ForEach(GalaxyAppleMap.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    SecureField("Mapbox public token (pk.…)", text: $entry)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if entry != token {
                        Button("Save public token") { token = entry.trimmingCharacters(in: .whitespacesAndNewlines); entry = token }
                            .disabled(!entry.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pk."))
                    }
                    if enabled && !token.hasPrefix("pk.") { Text("Add a Mapbox public token to display this map. Apple Maps is available in the meantime.").font(.footnote) }
                    if enabled {
                        Picker("Basemap", selection: $basemap) {
                            ForEach(GalaxyBasemap.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if [.standard, .standardSatellite].contains(basemap) {
                            NavigationLink("Labels, theme and colors") {
                                StandardMapSettings(satellite: basemap == .standardSatellite, settings: Binding(get: { BasemapOptions.decode(styleData) },
                                    set: { if let data = try? JSONEncoder().encode($0) { styleData = data } }))
                            }
                        }
                        Toggle("Show traffic congestion", isOn: $traffic)
                    }
                } header: { Text("Map appearance") } footer: { Text("The display map is shared by iPhone and CarPlay. The traffic overlay shows reported slowdowns.") }
                if router == "Mapbox Navigator" {
                    Section {
                        Toggle("Show speed limits", isOn: $speedLimits)
                        Toggle("Show signals and stop signs", isOn: $intersections)
                        Toggle("Use night colors in tunnels", isOn: $darkTunnels)
                        Toggle("Fade the road already traveled", isOn: $fadeRoute)
                    } header: { Text("Mapbox Navigator") } footer: {
                        Text("Choose iPhone on the destination card to open Mapbox’s turn-by-turn screen with spoken guidance and rerouting. This screen runs on iPhone. Galaxy guidance also appears on CarPlay.")
                    }
                }
                if token.hasPrefix("pk.") {
                    Section("Downloads") {
                        NavigationLink("Offline maps and routing") {
                            OfflineNavigationAreas(token: token, style: basemap, navigation: model.navigationServices.navigation)
                        }
                    }
                }
                if enabled {
                    Section("Mapbox driving camera") {
                        Stepper("Cruising tilt · \(Int(pitch))°", value: $pitch, in: 0...80, step: 2)
                        Stepper("Zoom adjustment · \(zoom.formatted())", value: $zoom, in: -2...2, step: 0.25)
                        Text("Higher tilt looks farther down the road. Positive zoom shows a closer view. The camera still adapts as you approach turns.").font(.footnote)
                    }
                }
            }
            .navigationTitle("Navigation settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.onAppear { entry = token }
    }
}
final class DriveMarkerPerspective: ObservableObject {
    @Published private(set) var pitch = 0.0

    func update(_ degrees: Double) {
        let next = degrees.rounded()
        if pitch != next { pitch = next }
    }
}
struct DrivePositionMarker: View {
    static let diameter: CGFloat = 28
    static let barClearance: CGFloat = 8
    @ObservedObject var perspective: DriveMarkerPerspective
    let following: Bool
    let comma: Bool

    var body: some View {
        Image(systemName: following ? "location.north.fill" : "circle.fill")
            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter).background(StarPilotTheme.accent, in: Circle())
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .rotation3DEffect(.degrees(following ? -perspective.pitch * 0.78 : 0),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.22)
            .accessibilityLabel(comma ? "Comma location" : "Your location")
    }
}

struct CarDisplayMapOptions: Equatable {
    let overview: Bool
    let zoomFactor: Double
    let dashboard: Bool

    static func followX(in frame: CGRect, dashboard: Bool, rightToLeft: Bool) -> CGFloat {
        guard !dashboard else { return frame.midX }
        // Leave the leading side to the maneuver and ETA cards and keep clear of the trailing buttons.
        let trailingMargin = min(frame.width / 2, max(52, frame.width * 0.22))
        return rightToLeft ? frame.minX + trailingMargin : frame.maxX - trailingMargin
    }
}

struct MapboxDriveMap: View {
    private static let carArrow = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
        let disk = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 28, height: 28))
        StarPilotTheme.routePurple.setFill()
        disk.fill()
        UIColor.white.setStroke()
        disk.lineWidth = 2
        disk.stroke()
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 15, y: 5))
        arrow.addLine(to: CGPoint(x: 22, y: 22))
        arrow.addLine(to: CGPoint(x: 15, y: 18))
        arrow.addLine(to: CGPoint(x: 8, y: 22))
        arrow.close()
        UIColor.white.setFill()
        arrow.fill()
    }
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
    @Environment(\.layoutDirection) private var layoutDirection
    let markerPerspective: DriveMarkerPerspective
    let carDisplay: CarDisplayMapOptions?
    let phoneSafeTop: CGFloat
    let headerBottom: CGFloat
    let tripFrame: CGRect
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("navigation.standardOptions") private var styleData = Data()
    @AppStorage("navigation.basemap") private var basemap = GalaxyBasemap.standard
    @AppStorage("navigation.cameraPitch") private var cruisingPitch = 68.0
    @AppStorage("navigation.zoomAdjustment") private var zoomAdjustment = 0.0
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

    init(navigation: NavigationModel, token: String, markerPerspective: DriveMarkerPerspective, tripFrame: CGRect, headerBottom: CGFloat = 0, phoneSafeTop: CGFloat = 0, carDisplay: CarDisplayMapOptions? = nil) {
        self.navigation = navigation
        self.markerPerspective = markerPerspective
        self.carDisplay = carDisplay
        self.phoneSafeTop = phoneSafeTop
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
            let rtl = layoutDirection == .rightToLeft
            let carFrame = CGRect(x: rtl ? geometry.safeAreaInsets.trailing : geometry.safeAreaInsets.leading, y: 0,
                                  width: max(0, bounds.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing),
                                  height: bounds.height)
            let anchor = CGPoint(
                x: carDisplay == nil ? (tripFrame.isEmpty ? bounds.width / 2 : min(bounds.width * 0.9, max(bounds.width * 0.1, tripFrame.midX - bounds.minX))) :
                    CarDisplayMapOptions.followX(in: carFrame, dashboard: carDisplay?.dashboard == true, rightToLeft: rtl),
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
                            .lineOcclusionOpacity(driving ? 0.28 : 0)
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
                    if carDisplay != nil, driving, following, let point = position(at: clock.date) {
                        GeoJSONSource(id: "galaxy-car-position").data(.geometry(.point(Point(aligned(point)))))
                        StyleImage(id: "galaxy-car-arrow", image: Self.carArrow)
                        SymbolLayer(id: "galaxy-car-marker", source: "galaxy-car-position")
                            .slot(.top).iconImage("galaxy-car-arrow")
                            .iconPitchAlignment(.viewport).iconRotationAlignment(.viewport)
                            .iconAllowOverlap(true).iconIgnorePlacement(true).iconOcclusionOpacity(1)
                    } else if !(driving && following), let point = position(at: clock.date) {
                        MapViewAnnotation(coordinate: aligned(point)) {
                            DrivePositionMarker(perspective: markerPerspective, following: false, comma: commaTrip)
                        }
                    }
                }
                .mapStyle(BasemapOptions.decode(styleData).style(basemap: basemap, dark: colorScheme == .dark, labels: labels, places: showPlaces, driving: driving))
                .usesSafeAreaInsetsAsPadding(!anchored)
                .ornamentOptions(mapOrnaments(headerInset: headerInset, scaleInset: 2 - max(0, phoneSafeTop - bounds.minY), panel: panel))
                .onCameraChanged { event in
                    if driving && following { markerPerspective.update(Double(event.cameraState.pitch)) }
                }
                .onMapLoadingError {
                    if $0.type == .style {
                        navigation.notice = "Mapbox couldn’t load. Check your internet connection and public token in Navigation map settings."
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

    private func mapOrnaments(headerInset: CGFloat, scaleInset: CGFloat, panel: CGFloat) -> OrnamentOptions {
        var options = OrnamentOptions()
        if let carDisplay {
            options.scaleBar.visibility = .hidden
            // Leave the screen edges for CarPlay’s dock and zoom buttons.
            let inset: CGFloat = carDisplay.dashboard ? 8 : 52
            let edge: OrnamentPosition = carDisplay.dashboard ? .bottomTrailing : .topTrailing
            let y: CGFloat = carDisplay.dashboard ? panel + 6 : 8
            options.attributionButton.position = edge
            options.attributionButton.margins = CGPoint(x: inset, y: y)
            options.logo.position = edge
            options.logo.margins = CGPoint(x: inset + 28, y: y)
        } else {
            // Scale margins are relative to the native map's safe area. Use the
            // strip above the maneuver card without changing its layout.
            options.scaleBar.margins = CGPoint(x: 12, y: driving ? scaleInset : headerInset)
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
        let drivingZoom = carDisplay == nil ? 18.0 : 17.6
        let zoom = driving ? drivingZoom + zoomAdjustment - 0.8 * log2(distance / 1200) : 16.8
        let measuredBearing = commaTrip ? navigation.commaHeading : navigation.location?.course ?? -1
        let validBearing = measuredBearing.isFinite && (0..<360).contains(measuredBearing)
        let moving = speed >= 1.2 || displacement >= 6
        if validBearing && (!continuous || moving) {
            cameraBearing = NavigationMapMotion.heading(from: cameraBearing, to: measuredBearing,
                fraction: continuous ? 1 - exp(-dt / 0.5) : 1)
        }
        cameraZoom += (zoom - cameraZoom) * (continuous ? 1 - exp(-dt / 2) : 1)
        let targetPitch = driving ? navigation.followPitch(cruising: cruisingPitch, speed: speed) : 48
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
private struct BasemapOptions: Codable, Equatable {
    var showTransitLabels = true
    var showRoadLabels = true
    var showPedestrianRoads = true
    var show3dObjects = true
    var showAdminBoundaries = true
    var showLandmarkIconLabels = true
    var showLandmarkIcons = true
    var theme = "default"
    var light = "automatic"
    var font = "DIN Pro"
    var back = "circle"
    var mode = "default"
    var colors: [String: String] = [:]
    var density = 3.0
    var brightness = 0.4
    var themeData = ""
    static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
    var showRoadsAndTransit = true
    func style(basemap: GalaxyBasemap, dark: Bool, labels: PointLabels, places: Bool, driving: Bool) -> MapboxMaps.MapStyle {
        if basemap == .standardSatellite {
            return .standardSatellite(lightPreset: .init(rawValue: light == "automatic" ? (dark ? "night" : "day") : light),
            font: .init(rawValue: font), showPointOfInterestLabels: labels.visible(driving: driving),
            showTransitLabels: showTransitLabels, showPlaceLabels: places, showRoadLabels: showRoadLabels,
            showRoadsAndTransit: showRoadsAndTransit, showPedestrianRoads: showPedestrianRoads,
            backgroundPointOfInterestLabels: .init(rawValue: back),
            colorAdminBoundaries: colors["AdminBoundaries"].map { StyleColor(rawValue: $0) },
            colorModePointOfInterestLabels: .init(rawValue: mode),
            colorMotorways: colors["Motorways"].map { StyleColor(rawValue: $0) },
            colorPlaceLabelHighlight: colors["PlaceLabelHighlight"].map { StyleColor(rawValue: $0) },
            colorPlaceLabels: colors["PlaceLabels"].map { StyleColor(rawValue: $0) },
            colorPlaceLabelSelect: colors["PlaceLabelSelect"].map { StyleColor(rawValue: $0) },
            colorPointOfInterestLabels: colors["PointOfInterestLabels"].map { StyleColor(rawValue: $0) },
            colorRoadLabels: colors["RoadLabels"].map { StyleColor(rawValue: $0) },
            colorRoads: colors["Roads"].map { StyleColor(rawValue: $0) },
            colorTrunks: colors["Trunks"].map { StyleColor(rawValue: $0) },
            densityPointOfInterestLabels: labels == .automatic && driving ? min(1, density) : density,
            roadsBrightness: brightness, showAdminBoundaries: showAdminBoundaries)
        }
        guard basemap == .standard else { return MapboxMaps.MapStyle(uri: basemap.uri) }
        return .standard(theme: .init(rawValue: theme),
            lightPreset: .init(rawValue: light == "automatic" ? (dark ? "night" : "day") : light),
            font: .init(rawValue: font), showPointOfInterestLabels: labels.visible(driving: driving),
            showTransitLabels: showTransitLabels, showPlaceLabels: places, showRoadLabels: showRoadLabels,
            showPedestrianRoads: showPedestrianRoads, show3dObjects: show3dObjects,
            backgroundPointOfInterestLabels: .init(rawValue: back),
            colorAdminBoundaries: colors["AdminBoundaries"].map { StyleColor(rawValue: $0) },
            colorBuildingHighlight: colors["BuildingHighlight"].map { StyleColor(rawValue: $0) },
            colorBuildingSelect: colors["BuildingSelect"].map { StyleColor(rawValue: $0) },
            colorGreenspace: colors["Greenspace"].map { StyleColor(rawValue: $0) },
            colorModePointOfInterestLabels: .init(rawValue: mode),
            colorMotorways: colors["Motorways"].map { StyleColor(rawValue: $0) },
            colorPlaceLabelHighlight: colors["PlaceLabelHighlight"].map { StyleColor(rawValue: $0) },
            colorPlaceLabels: colors["PlaceLabels"].map { StyleColor(rawValue: $0) },
            colorPlaceLabelSelect: colors["PlaceLabelSelect"].map { StyleColor(rawValue: $0) },
            colorPointOfInterestLabels: colors["PointOfInterestLabels"].map { StyleColor(rawValue: $0) },
            colorRoadLabels: colors["RoadLabels"].map { StyleColor(rawValue: $0) },
            colorRoads: colors["Roads"].map { StyleColor(rawValue: $0) },
            colorTrunks: colors["Trunks"].map { StyleColor(rawValue: $0) },
            colorWater: colors["Water"].map { StyleColor(rawValue: $0) },
            densityPointOfInterestLabels: labels == .automatic && driving ? min(1, density) : density,
            roadsBrightness: brightness, showAdminBoundaries: showAdminBoundaries,
            showLandmarkIconLabels: showLandmarkIconLabels, showLandmarkIcons: showLandmarkIcons,
            themeData: theme == "custom" && !themeData.isEmpty ? themeData : nil)
    }
}

private struct StandardMapSettings: View {
    let satellite: Bool
    @Binding var settings: BasemapOptions
    @AppStorage(NavigationMapPreference.poiKey) private var labels = PointLabels.always
    @AppStorage(NavigationMapPreference.placesKey) private var places = true
    var body: some View {
        Form {
            Section("Appearance") {
                if !satellite { choice("Color theme", $settings.theme, ["default","faded","monochrome","custom"]) }
                choice("Lighting", $settings.light, ["automatic","dawn","day","dusk","night"])
                choice("Label typeface", $settings.font, ["DIN Pro","Alegreya","Alegreya SC","Asap","Barlow","EB Garamond","Faustina","Frank Ruhl Libre","Heebo","Inter","Lato","League Mono","Montserrat","Manrope","Noto Sans CJK JP","Open Sans","Poppins","Raleway","Roboto","Roboto Mono","Rubik","Source Code Pro","Source Sans Pro","Spectral","Ubuntu"])
                if !satellite && settings.theme == "custom" {
                    TextField("Mapbox theme LUT data", text: $settings.themeData)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Road brightness", value: settings.brightness.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $settings.brightness, in: 0...1, step: 0.05).accessibilityLabel("Road brightness")
            }
            Section("Map detail") {
                if satellite { Toggle("Road and transit overlay", isOn: $settings.showRoadsAndTransit) }
                Toggle("Transit stops and stations", isOn: $settings.showTransitLabels)
                Toggle("Street names and highway shields", isOn: $settings.showRoadLabels)
                Toggle("Walking paths and trails", isOn: $settings.showPedestrianRoads)
                if !satellite { Toggle("3D buildings, trees and landmarks", isOn: $settings.show3dObjects) }
                Toggle("Administrative boundaries", isOn: $settings.showAdminBoundaries)
                if !satellite { Toggle("Landmark names", isOn: $settings.showLandmarkIconLabels) }
                if !satellite { Toggle("Landmark icons", isOn: $settings.showLandmarkIcons) }
                Toggle("City and neighborhood names", isOn: $places)
            }
            Section("Points of interest") {
                Picker("Visibility", selection: $labels) {
                    Text("Always").tag(PointLabels.always)
                    Text("Fewer during guidance").tag(PointLabels.automatic)
                    Text("Only while browsing").tag(PointLabels.browsing)
                    Text("Off").tag(PointLabels.off)
                }
                choice("Point of interest badges", $settings.back, ["circle","none"])
                choice("Point of interest colors", $settings.mode, ["default","single"])
                Stepper("Label density · \(settings.density.formatted())", value: $settings.density, in: 1...5, step: 0.5)
            }
            Section {
                palette("AdminBoundaries", "Admin boundaries")
                if !satellite { palette("BuildingHighlight", "Building highlight") }
                if !satellite { palette("BuildingSelect", "Building select") }
                if !satellite { palette("Greenspace", "Greenspace") }
                palette("Motorways", "Motorways")
                palette("PlaceLabelHighlight", "Place label highlight")
                palette("PlaceLabels", "Place labels")
                palette("PlaceLabelSelect", "Place label select")
                palette("PointOfInterestLabels", "Point of interest labels")
                palette("RoadLabels", "Road labels")
                palette("Roads", "Roads")
                palette("Trunks", "Trunks")
                if !satellite { palette("Water", "Water") }
            } header: { Text("Custom colors") } footer: {
                Text("Each color overrides the theme for that feature. Use the reset arrow to restore its theme color. Highlight and selection colors appear when a feature has that state.")
            }
        }.navigationTitle(satellite ? "Satellite map style" : "Standard map style")
    }
    private func choice(_ title: String, _ selection: Binding<String>, _ values: [String]) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { Text($0.prefix(1).uppercased() + String($0.dropFirst())).tag($0) }
        }
    }
    private func palette(_ key: String, _ title: String) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: {
                let hex = settings.colors[key].flatMap { UInt32($0.dropFirst(), radix: 16) } ?? 0x808080
                return Color(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
            }, set: { value in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                guard UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                settings.colors[key] = String(format: "#%02X%02X%02X", Int((255*r).rounded()), Int((255*g).rounded()), Int((255*b).rounded()))
            }), supportsOpacity: false)
            if settings.colors[key] != nil {
                Button { settings.colors.removeValue(forKey: key) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).accessibilityLabel("Restore theme color for " + title)
            }
        }
    }
}
