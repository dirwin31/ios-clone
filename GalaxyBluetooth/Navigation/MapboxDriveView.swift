import SwiftUI
import MapKit
import MapboxMaps

enum NavigationMapPreference {
    static let enabledKey = "navigation.mapboxEnabled"
    static let tokenKey = "navigation.mapboxPublicToken"
    static let promptedKey = "navigation.mapboxSetupSeen"

    static func publicToken(from entry: String) -> String? {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048, value.hasPrefix("pk."), value.count > 3,
              value.dropFirst(3).utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte)
              }) else { return nil }
        return value
    }

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

struct CommaMapKeySetup: View {
    @ObservedObject var bluetooth: BluetoothTransport
    let save: (String) -> Void
    @State private var attempt: UUID?
    @State private var message = ""

    var body: some View {
        Section {
            Text("1. Park and connect Galaxy to your comma over Bluetooth.")
            Text("2. On the comma, open Bluetooth settings and tap Share Mapbox key.")
            Text("3. Within two minutes, tap the button below to save the key on this iPhone.")
            Button {
                attempt = UUID()
            } label: {
                Label("Use key from comma", systemImage: "key")
            }.disabled(!bluetooth.connected || attempt != nil)
            if !bluetooth.connected {
                Text("Waiting for a paired comma over Bluetooth.").font(.footnote)
            } else if attempt != nil {
                ProgressView("Checking comma…")
            } else if !message.isEmpty {
                Text(message).font(.footnote)
            }
        } header: { Text("Already use Mapbox on your comma?") } footer: {
            Text("If your comma has no Share Mapbox key button, paste your public token instead.")
        }
        .task(id: attempt) {
            guard let requested = attempt else { return }
            let session = bluetooth.sessionIdentifier
            defer { if attempt == requested { attempt = nil } }
            do {
                let reply = try await bluetooth.request(path: "/_bridge/mapbox-public-token", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, bluetooth.connected, bluetooth.sessionIdentifier == session else { return }
                struct SharedKey: Decodable { let publicToken: String }
                if reply.status == 200,
                   let shared = try? JSONDecoder().decode(SharedKey.self, from: reply.bodyData),
                   let token = NavigationMapPreference.publicToken(from: shared.publicToken) {
                    save(token)
                } else {
                    message = "No key was shared. Tap Share Mapbox key on your comma and try again, or paste your public token."
                }
            } catch {
                if !Task.isCancelled { message = "Couldn’t reach your comma. Check Bluetooth and try again." }
            }
        }
    }
}

private enum PointLabels: String {
    case automatic, browsing, always, off

    func visible(driving: Bool) -> Bool {
        self != .off && (self != .browsing || !driving)
    }
}


private enum DriveRouteColor: String, CaseIterable {
    case purple, blue, orange, yellow, teal, white
    var color: UIColor {
        switch self {
        case .purple: StarPilotTheme.routePurple
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .teal: .systemTeal
        case .white: .white
        }
    }
}

private struct RouteLineSettings: View {
    @AppStorage("navigation.routeColor") private var color = DriveRouteColor.purple
    @AppStorage("navigation.routeWidth") private var width = 7.0
    @AppStorage("navigation.routeBorder") private var border = 1.0
    @AppStorage("navigation.routeOcclusion") private var occlusion = 0.28
    var body: some View {
        Form {
            Section("Route appearance") {
                Picker("Line color", selection: $color) {
                    ForEach(DriveRouteColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Stepper("Line width · \(width.formatted()) pt", value: $width, in: 2...14, step: 0.5)
                Stepper("Outline width · \(border.formatted()) pt", value: $border, in: 0...4, step: 0.5)
            }
            Section {
                LabeledContent("Visibility", value: occlusion.formatted(.percent))
                Slider(value: $occlusion, in: 0...1).accessibilityLabel("Route visibility behind buildings")
            } header: { Text("Behind buildings") } footer: {
                Text("Increase visibility to see more of your route where a 3D building covers the road during guidance.")
            }
            Button("Restore route appearance") { color = .purple; width = 7; border = 1; occlusion = 0.28 }
        }.navigationTitle("Route line")
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
    case standard = "Standard", standardSatellite = "Standard Satellite", streets = "Streets", outdoors = "Outdoors", light = "Light", dark = "Dark", satellite = "Satellite", satelliteStreets = "Satellite Streets", studio = "Mapbox Studio"
    var uri: StyleURI {
        switch self {
        case .standard: .standard
        case .standardSatellite: .standardSatellite
        case .streets: .streets
        case .outdoors: .outdoors
        case .light: .light
        case .dark: .dark
        case .satellite: .satellite
        case .studio: Self.studioURI(UserDefaults.standard.string(forKey: "navigation.studioStyle") ?? "") ?? .standard
        case .satelliteStreets: .satelliteStreets
        }
    }
    static func studioURI(_ input: String) -> StyleURI? {
        guard let url = URLComponents(string: input), url.scheme == "mapbox", url.host == "styles",
              url.path.split(separator: "/").count == 2, url.query == nil, url.fragment == nil else { return nil }
        return StyleURI(rawValue: input)
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
    @AppStorage("navigation.mappedJunctions") private var mappedJunctions = false
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
    @AppStorage(NavigationModel.phoneOnlyKey) private var phoneOnly = false
    @AppStorage("navigation.avoidCashTolls") private var cashTolls = false
    @AppStorage("navigation.avoidUnpaved") private var unpaved = false
    @AppStorage("navigation.vehicleLimits") private var limits = false
    @AppStorage("navigation.max_height") private var height = 1.6
    @AppStorage("navigation.max_width") private var width = 1.9
    @AppStorage("navigation.max_weight") private var weight = 2.5
    @AppStorage("navigation.sdkSource") private var routeSource = "Automatic"
    @AppStorage("navigation.sdkLocalVoice") private var localVoice = false
    @AppStorage("navigation.sdkReroute") private var reroute = true
    @AppStorage("navigation.sdkFasterRoutes") private var faster = true
    @State private var styleEntry = ""
    @AppStorage("navigation.studioStyle") private var studioStyle = ""
    @State private var entry = ""
    @State private var initialRouteOptions: [AnyHashable] = []
    @State private var initialPhoneOnly = false

    private var routeOptions: [AnyHashable] {
        [router, enabled, token, alternatives, tolls, cashTolls, ferries, motorways, unpaved, limits, height, width, weight]
    }

    private var effectiveProvider: String {
        PhoneRoute.directionsProvider(router, sharing: false, automaticUsesMapbox: enabled && token.hasPrefix("pk."))
    }

    private var providerExplanation: String {
        switch router {
        case "Apple Maps":
            return "Apple calculates the route using your iPhone. Galaxy shows the turns on iPhone and CarPlay. You can use this without a comma or a Mapbox key."
        case "Mapbox Driving":
            return "Mapbox calculates a driving route using your iPhone’s connection and public token. Galaxy displays the directions on iPhone and CarPlay."
        case "Mapbox Traffic":
            return "Mapbox uses reported traffic speeds to choose a route and estimate arrival. The traffic overlay under Map appearance controls which slowdowns you see."
        case "Mapbox Navigator":
            return "Opens Mapbox’s spoken turn-by-turn guidance on iPhone. Download an area in advance to use its routing data offline."
        case "Google Maps app":
            return "Opens the destination in the Google Maps app on iPhone. For Google Routes on your comma, turn off iPhone-only directions and select Google Routes in Comma settings."
        case "Waze app":
            return "Opens the destination in the selected service. That service calculates the trip and provides the directions."
        default:
            return "Galaxy uses Mapbox Driving when the Mapbox display map and a public token are available. Otherwise it uses Apple Maps."
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                trips.listRowBackground(menuPanel)
                Section {
                    settingLink("Comma settings", icon: "car.fill", detail: "Google Routes, Mapbox and GPS") {
                        CommaNavigationPreferences(connection: model.navigationServices.connection)
                    }
                    if phoneOnly {
                        settingLink("iPhone directions", icon: "iphone", detail: effectiveProvider) {
                            self.directions
                            self.navigator
                        }
                    }
                    settingLink("Map appearance", icon: "map.fill", detail: "Map style, traffic, camera and Mapbox token") {
                        self.appearance
                        self.camera
                    }.accessibilityIdentifier("navigation-map-appearance")
                    downloads
                }.listRowBackground(menuPanel)
            }
            .scrollContentBackground(.hidden)
            .background(menuBackground)
            .tint(StarPilotTheme.accent)
            .navigationTitle("Navigation settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.onAppear {
            entry = token; styleEntry = studioStyle
            initialRouteOptions = routeOptions
            initialPhoneOnly = phoneOnly
        }
        .onDisappear {
            let nav = model.navigationServices.navigation
            guard model.navigationEnabled, !nav.navigating, nav.destination != nil else { return }
            if initialPhoneOnly != phoneOnly {
                Task { await nav.refreshTripPreference() }
            } else if !nav.sendToComma, routeOptions != initialRouteOptions {
                Task { await nav.preview(from: nav.plannedStart) }
            }
        }
    }
    @Environment(\.colorScheme) private var colorScheme

    private var menuBackground: Color {
        colorScheme == .dark ? StarPilotTheme.background : Color(red: 0.93, green: 0.90, blue: 0.98)
    }

    private var menuPanel: Color {
        colorScheme == .dark ? StarPilotTheme.panel : Color(red: 0.88, green: 0.83, blue: 0.95)
    }

    private func settingLink<Content: View>(_ title: LocalizedStringKey, icon: String, detail: String,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content().listRowBackground(menuPanel) }
                .scrollContentBackground(.hidden)
                .background(menuBackground)
                .navigationTitle(title)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).accessibilityHidden(true)
                    .foregroundStyle(StarPilotTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(StarPilotTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }
    }

    @ViewBuilder private var trips: some View {
        Section {
            Toggle("Enable navigation", isOn: $model.navigationEnabled)
            Toggle("Use iPhone-only directions", isOn: $phoneOnly)
                .accessibilityIdentifier("navigation-phone-only")
            Text(phoneOnly ? "New trips use your iPhone for directions. Your comma receives no destination."
                           : "Your iPhone sends the destination to your comma. Choose Mapbox or Google Routes in Comma settings.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Distance units", selection: $units) {
                Text("System").tag(NavigationDistanceUnits.system)
                Text("Metric").tag(NavigationDistanceUnits.metric)
                Text("Imperial").tag(NavigationDistanceUnits.imperial)
            }.accessibilityIdentifier("navigation-distance-units")
            Toggle("Remember destinations", isOn: $remember)
        } header: { Text("Trips") } footer: { Text("Remember destinations saves recent places on this iPhone.") }
    }

    @ViewBuilder private var directions: some View {
        Section {
            Picker("Directions provider", selection: $router) {
                ForEach(["Automatic", "Apple Maps", "Mapbox Driving", "Mapbox Traffic", "Mapbox Navigator"] + ExternalNavigator.allCases.map(\.rawValue), id: \.self) { Text($0).tag($0) }
            }
            if ExternalNavigator(rawValue: effectiveProvider) == nil { Toggle("Offer alternative routes", isOn: $alternatives) }
            if ["Mapbox Driving", "Mapbox Traffic"].contains(router) || (router == "Automatic" && enabled && token.hasPrefix("pk.")) {
                Toggle("Show mapped intersections on iPhone", isOn: $mappedJunctions)
                Text("During iPhone guidance, see signs, lights and rail crossings mapped at an upcoming junction. A sign may face another road. The navigation log records when a label appears or clears for drive review.").font(.footnote)
            }
            if router.hasPrefix("Mapbox") || (router == "Automatic" && enabled && token.hasPrefix("pk.")) {
                NavigationLink("Roads and vehicle preferences") {
                    Form {
                        Section("Roads to avoid") {
                            Toggle("Toll roads", isOn: $tolls)
                            Toggle("Cash-only tolls", isOn: $cashTolls)
                            Toggle("Ferries", isOn: $ferries)
                            Toggle("Motorways", isOn: $motorways)
                            Toggle("Unpaved roads", isOn: $unpaved)
                        }
                        Section {
                            Toggle("Use vehicle dimensions", isOn: $limits)
                            if limits {
                                Stepper("Height · \(height.formatted()) m", value: $height, in: 0.1...10, step: 0.1)
                                Stepper("Width · \(width.formatted()) m", value: $width, in: 0.1...10, step: 0.1)
                                Stepper("Gross weight · \(weight.formatted()) t", value: $weight, in: 0.1...100, step: 0.1)
                            }
                        } header: { Text("Vehicle clearance") } footer: { Text("Mapbox accounts for known road restrictions. Coverage varies by area.") }
                    }.navigationTitle("Route preferences")
                }
            }
        } header: { Text("iPhone directions") } footer: {
            Text(providerExplanation)
        }
    }

    @ViewBuilder private var appearance: some View {
        if enabled && token.isEmpty && entry.isEmpty {
            CommaMapKeySetup(bluetooth: model.bluetooth) { value in
                guard enabled, token.isEmpty, entry.isEmpty else { return }
                token = value
                entry = value
            }
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
            if !token.isEmpty && entry == token {
                Button("Remove saved token", role: .destructive) { entry = ""; token = "" }
            }
            if entry != token {
                Button("Save public token") {
                    guard let value = NavigationMapPreference.publicToken(from: entry) else { return }
                    token = value; entry = value
                }
                .disabled(NavigationMapPreference.publicToken(from: entry) == nil)
            }
            if enabled && !token.hasPrefix("pk.") { Text("Add a Mapbox public token to display this map. Apple Maps is available in the meantime.").font(.footnote) }
            if enabled {
                Picker("Basemap", selection: $basemap) {
                    ForEach(GalaxyBasemap.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if basemap == .studio {
                    TextField("mapbox://styles/owner/style", text: $styleEntry)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Apply Studio style") { studioStyle = styleEntry }
                        .disabled(GalaxyBasemap.studioURI(styleEntry) == nil || studioStyle == styleEntry)
                    Text("Paste a published Mapbox Studio style accessible with your public token. Standard is shown until a style is saved.")
                        .font(.footnote)
                }
                if [.standard, .standardSatellite].contains(basemap) {
                    NavigationLink("Labels, theme and colors") {
                        StandardMapSettings(satellite: basemap == .standardSatellite, settings: Binding(get: { BasemapOptions.decode(styleData) },
                            set: { if let data = try? JSONEncoder().encode($0) { styleData = data } }))
                    }
                }
                NavigationLink("Route line") { RouteLineSettings() }
                Toggle("Show traffic congestion", isOn: $traffic)
            }
        } header: { Text("Map appearance") } footer: { Text("The display map is shared by iPhone and CarPlay. The traffic overlay shows reported slowdowns.") }
    }

    @ViewBuilder private var navigator: some View {
        if router == "Mapbox Navigator" {
            Section {
                Picker("Routing data", selection: $routeSource) {
                    Text("Online with offline fallback").tag("Automatic")
                    Text("Online only").tag("Online")
                    Text("Downloaded areas only").tag("Offline")
                }
                Toggle("Use iPhone voices only", isOn: $localVoice)
                Toggle("Reroute after a missed turn", isOn: $reroute)
                Toggle("Look for faster routes", isOn: $faster)
                Toggle("Show speed limits", isOn: $speedLimits)
                Toggle("Show signals and stop signs", isOn: $intersections)
                Toggle("Use night colors in tunnels", isOn: $darkTunnels)
                Toggle("Fade the road already traveled", isOn: $fadeRoute)
            } header: { Text("Mapbox Navigator") } footer: {
                Text("Start the route on your iPhone to open Mapbox Navigator with spoken guidance and rerouting.")
            }
        }
    }

    @ViewBuilder private var downloads: some View {
        if token.hasPrefix("pk.") {
            NavigationLink {
                OfflineNavigationAreas(token: token, style: basemap, navigation: model.navigationServices.navigation)
            } label: {
                Label("Offline maps and routing", systemImage: "arrow.down.circle")
            }
        }
    }

    @ViewBuilder private var camera: some View {
        if enabled {
            Section("Mapbox driving camera") {
                Stepper("Cruising tilt · \(Int(pitch))°", value: $pitch, in: 0...80, step: 2)
                Stepper("Zoom adjustment · \(zoom.formatted())", value: $zoom, in: -2...2, step: 0.25)
                Text("Higher tilt looks farther down the road. Positive zoom shows a closer view. The camera still adapts as you approach turns.").font(.footnote)
            }
        }
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
    let phoneMapHeight: CGFloat
    let mapHeight: CGFloat
    let maximumFPS: Float

    static func followY(height: CGFloat, bottomInset: CGFloat, dashboard: Bool) -> CGFloat {
        if dashboard {
            // CarPlay can draw the ETA strip over the map without including it in the safe area.
            let etaStripHeight: CGFloat = 48
            let markerRadius: CGFloat = 15
            return max(height / 2, height - max(bottomInset, etaStripHeight) - markerRadius - 8)
        }
        return max(height / 2, height - max(0, bottomInset) - min(32, height * 0.15))
    }

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
    let headerBottom: CGFloat
    let tripFrame: CGRect
    let plannerInsets: EdgeInsets
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("navigation.standardOptions") private var styleData = Data()
    @AppStorage("navigation.basemap") private var basemap = GalaxyBasemap.standard
    @AppStorage("navigation.studioStyle") private var studioStyle = ""
    @AppStorage("navigation.routeColor") private var routeColor = DriveRouteColor.purple
    @AppStorage("navigation.routeWidth") private var routeWidth = 7.0
    @AppStorage("navigation.routeBorder") private var routeBorder = 1.0
    @AppStorage("navigation.routeOcclusion") private var occlusion = 0.28
    @AppStorage("navigation.cameraPitch") private var cruisingPitch = 68.0
    @AppStorage("navigation.zoomAdjustment") private var zoomAdjustment = 0.0
    @State private var viewport: Viewport
    @State private var styleOptions = BasemapOptions.decode(UserDefaults.standard.data(forKey: "navigation.standardOptions") ?? Data())
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

    init(navigation: NavigationModel, token: String, markerPerspective: DriveMarkerPerspective, tripFrame: CGRect, headerBottom: CGFloat = 0, plannerInsets: EdgeInsets = EdgeInsets(), carDisplay: CarDisplayMapOptions? = nil) {
        self.navigation = navigation
        self.markerPerspective = markerPerspective
        self.carDisplay = carDisplay
        self.headerBottom = headerBottom
        self.tripFrame = tripFrame
        self.plannerInsets = plannerInsets
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
        if carDisplay != nil { return navigation.carPlayLocation(at: date)?.coordinate }
        if commaTrip {
            guard navigation.commaFeedReady, date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4 else { return nil }
            return navigation.commaPosition
        }
        return navigation.goodLocation?.coordinate
    }

    // Bluetooth status can arrive between phone fixes. A newer nearby fix moves
    // only the display camera while comma guidance and its own position are live.
    private var cameraLocation: CLLocation? {
        if carDisplay != nil { return navigation.carPlayLocation(at: .now, commaSpeed: commaSpeed) }
        guard commaTrip else { return navigation.goodLocation }
        guard let point = position(at: .now) else { return nil }
        let sample = CLLocation(coordinate: point, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
            course: navigation.commaHeading, speed: commaSpeed, timestamp: navigation.commaPositionSampleDate)
        if let phone = navigation.goodLocation,
           (0...1.5).contains(-phone.timestamp.timeIntervalSinceNow),
           phone.horizontalAccuracy <= 15, phone.distance(from: sample) <= 30 {
            return phone
        }
        return sample
    }

    var body: some View {
        GeometryReader { geometry in
            let top = min(driving ? 190.0 : 90.0, geometry.size.height * 0.32)
            let bounds = geometry.frame(in: .global)
            let phoneInset = driving && !tripFrame.isEmpty ? min(bounds.height, max(0, bounds.maxY - tripFrame.minY)) : 0
            let panel: CGFloat = carDisplay == nil ? max(phoneInset, plannerInsets.bottom) : min(65, geometry.size.height * 0.24)
            let headerInset = max(8, headerBottom - bounds.minY + 2)
            let rtl = layoutDirection == .rightToLeft
            let carFrame = CGRect(x: rtl ? geometry.safeAreaInsets.trailing : geometry.safeAreaInsets.leading, y: 0,
                                  width: max(0, bounds.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing),
                                  height: bounds.height)
            let anchor = CGPoint(
                x: carDisplay == nil ? (tripFrame.isEmpty ? bounds.width / 2 : min(bounds.width * 0.9, max(bounds.width * 0.1, tripFrame.midX - bounds.minX))) :
                    CarDisplayMapOptions.followX(in: carFrame, dashboard: carDisplay?.dashboard == true, rightToLeft: rtl),
                y: carDisplay.map { CarDisplayMapOptions.followY(height: bounds.height, bottomInset: geometry.safeAreaInsets.bottom, dashboard: $0.dashboard) }
                    ?? max(bounds.height * 0.35, bounds.height - panel - DrivePositionMarker.barClearance - DrivePositionMarker.diameter / 2))
            let dx = 2 * anchor.x - bounds.width, dy = 2 * anchor.y - bounds.height
            let padding = driving ? EdgeInsets(top: max(0, dy), leading: max(0, dx), bottom: max(0, -dy), trailing: max(0, -dx))
                                  : EdgeInsets(top: top, leading: plannerInsets.leading, bottom: panel, trailing: 0)
            TimelineView(.animation(minimumInterval: 1, paused: driving && following)) { clock in
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
                            .lineOcclusionOpacity(driving ? occlusion : 0)
                            .lineColor(routeColor.color).lineWidth(routeWidth)
                            .lineBorderColor(UIColor(red: 0.27, green: 0.08, blue: 0.43, alpha: 1))
                            .lineBorderWidth(routeBorder).lineEmissiveStrength(1)
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
                    if !(driving && following), let point = position(at: clock.date) {
                        MapViewAnnotation(coordinate: aligned(point)) {
                            DrivePositionMarker(perspective: markerPerspective, following: false, comma: commaTrip)
                        }
                    }
                }
                .mapStyle(basemap == .studio ? MapboxMaps.MapStyle(uri: GalaxyBasemap.studioURI(studioStyle) ?? .standard) : styleOptions.style(basemap: basemap, dark: colorScheme == .dark, labels: labels, places: showPlaces, driving: driving))
                .frameRate(range: carDisplay.map { min(30, $0.maximumFPS)...$0.maximumFPS }, preferred: carDisplay?.maximumFPS)
                .usesSafeAreaInsetsAsPadding(!anchored)
                .ornamentOptions(mapOrnaments(headerInset: headerInset, panel: panel))
                .onCameraChanged { event in
                    if carDisplay == nil && driving && following { markerPerspective.update(Double(event.cameraState.pitch)) }
                }
                .onMapLoadingError {
                    if $0.type == .style {
                        navigation.notice = "Mapbox couldn’t load. Check your internet connection and public token in Navigation map settings."
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if carDisplay != nil, driving && following {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if position(at: .now) != nil {
                            Image(uiImage: Self.carArrow)
                                .position(anchor)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .onChange(of: styleData) { _, data in styleOptions = BasemapOptions.decode(data) }
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
                if !driving && navigation.destination != nil { preview(top: top, bottom: panel, padding: padding) }
                else if following && position(at: .now) != nil { follow(padding: padding) }
                else if carDisplay?.overview == true { overview(top: top, bottom: panel) }
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
            .onChange(of: navigation.commaPositionSampleDate) { _, _ in
                if commaTrip { updateCommaSpeed() }
            }
            .onChange(of: cameraLocation?.timestamp) { _, _ in
                follow(padding: padding)
            }
            .onChange(of: navigation.positionDisplayGeneration) { _, _ in lastCommaFix = nil; commaSpeed = 0; cameraFix = nil }
            .onChange(of: navigation.commaFeedReady) { _, ready in
                if ready { follow(padding: padding) }
            }
            .onChange(of: padding) { _, _ in
                if plannerInsets != EdgeInsets(), navigation.destination != nil, !following {
                    preview(top: top, bottom: panel, padding: padding)
                } else { follow(padding: padding, layoutChanged: true) }
            }
        }
    }

    private func mapOrnaments(headerInset: CGFloat, panel: CGFloat) -> OrnamentOptions {
        var options = OrnamentOptions()
        options.scaleBar.visibility = .hidden
        if let carDisplay {
            // Leave the screen edges for CarPlay’s dock and zoom buttons.
            let inset: CGFloat = carDisplay.dashboard ? 8 : 52
            let edge: OrnamentPosition = carDisplay.dashboard ? .bottomTrailing : .topTrailing
            let y: CGFloat = carDisplay.dashboard ? panel + 6 : 8
            options.attributionButton.position = edge
            options.attributionButton.margins = CGPoint(x: inset, y: y)
            options.logo.position = edge
            options.logo.margins = CGPoint(x: inset + 28, y: y)
        } else {
            options.compass.margins = CGPoint(x: 12, y: headerInset)
            options.logo.margins = CGPoint(x: plannerInsets.leading + 8, y: panel + 6)
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
        guard following, carDisplay == nil || driving || navigation.destination == nil,
              let fix = cameraLocation else { return }
        let point = fix.coordinate, stamp = fix.timestamp
        let previous = cameraFix
        let dt = previous.map { stamp.timeIntervalSince($0.timestamp) } ?? 0
        guard previous == nil || dt > 0 || layoutChanged else { return }
        let displacement = previous.map { fix.distance(from: $0) } ?? 0
        let continuous = previous != nil && dt >= 0 && dt <= 4 && displacement < 250
        let speed = max(0, fix.speed >= 0 ? fix.speed : (commaTrip ? commaSpeed : 0))
        let distance = NavigationMapMotion.cameraDistance(speed: speed, distanceToTurn: navigation.distanceToTurn)
        // Restrict the guide camera to street-level detail while keeping lookahead on faster roads.
        let zoom = driving ? 18.0 + zoomAdjustment - 0.8 * log2(distance / 1200) : 16.8
        let measuredBearing = fix.course >= 0 ? fix.course : (commaTrip ? navigation.commaHeading : -1)
        let validBearing = measuredBearing.isFinite && (0..<360).contains(measuredBearing)
        let phoneSpeed = navigation.goodLocation.flatMap { phone -> Double? in
            guard (0...2).contains(-phone.timestamp.timeIntervalSinceNow), phone.horizontalAccuracy <= 15,
                  phone.distance(from: fix) <= 30, phone.speed >= 0 else { return nil }
            return phone.speed
        }
        let motionSpeed = phoneSpeed ?? speed
        let moving = motionSpeed >= 1.2 || (phoneSpeed == nil && displacement >= 8)
        let steerCamera = NavigationMapMotion.reliableCourse(speed: motionSpeed, displacement: displacement,
            hasMeasuredSpeed: phoneSpeed != nil)
        if validBearing && (previous == nil || steerCamera) {
            cameraBearing = NavigationMapMotion.heading(from: cameraBearing, to: measuredBearing,
                fraction: continuous ? 1 - exp(-dt / 0.5) : 1)
        }
        cameraZoom += (zoom - cameraZoom) * (continuous ? 1 - exp(-dt / 2) : 1)
        let cruise = carDisplay.map { NavigationMapMotion.carPlayCruisingPitch(cruisingPitch,
            mapHeight: Double($0.mapHeight), phoneHeight: Double($0.phoneMapHeight)) } ?? cruisingPitch
        let targetPitch = driving ? navigation.followPitch(cruising: cruise, speed: speed) : 48
        cameraPitch += (targetPitch - cameraPitch) * (continuous ? 1 - exp(-dt / 1.2) : 1)
        let accepted = previous != nil && displacement < 15 && !moving ? previous?.coordinate ?? point : point
        let center = aligned(accepted)
        cameraFix = CLLocation(coordinate: accepted, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: stamp)
        // A short CarPlay screen otherwise shows only a narrow band of detailed ground.
        // Pull back while cruising and restore the close view as the turn approaches.
        let lookAheadZoom = driving && carDisplay != nil
            ? 0.65 * min(1, max(0, speed / 10)) * (navigation.distanceToTurn > 0 ? min(1, navigation.distanceToTurn / 180) : 1)
            : 0
        let camera = Viewport.camera(center: center, zoom: CGFloat(cameraZoom - lookAheadZoom - log2(carDisplay?.zoomFactor ?? 1)), bearing: cameraBearing,
                                     pitch: CGFloat(cameraPitch))
            .padding(padding)
        if reduceMotion || !continuous || layoutChanged { viewport = camera }
        else {
            let duration = carDisplay != nil
                ? NavigationMapMotion.carPlayAnimationDuration(interval: dt)
                : min(2.5, max(0.1, dt))
            withViewportAnimation(.linear(duration: duration)) { viewport = camera }
        }
    }

    private func updateCommaSpeed() {
        guard navigation.commaFeedReady, let point = navigation.commaPosition else { lastCommaFix = nil; commaSpeed = 0; return }
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
                             geometryPadding: .init(top: top + 8, leading: plannerInsets.leading + 24, bottom: bottom + 16, trailing: 24))
    }

    private func preview(top: CGFloat, bottom: CGFloat, padding: EdgeInsets) {
        guard !driving else { return }
        if routeShape != nil { overview(top: top, bottom: bottom) }
        else if let destination = navigation.destination {
            let camera = Viewport.camera(center: destination.coordinate, zoom: 16.8, pitch: 50)
            viewport = plannerInsets == EdgeInsets() ? camera : camera.padding(padding)
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

private struct CommaNavigationPreferences: View {
    let connection: CommaConnection
    @AppStorage(NavigationModel.phoneOnlyKey) private var phoneOnly = false

    private struct Snapshot: Decodable {
        let revision: String
        let mapProvider, routeProvider, gpsSource: String
        let avoidHighways, avoidTolls, avoidFerries: Bool
        let hasKey, hasGoogleKey, enabled: Bool
        let network: String?
        struct GoogleRoutesStatus: Decodable { let failure: String? }
        let googleRoutes: GoogleRoutesStatus?
    }

    @State private var original: Snapshot?
    @State private var loadedSession = ""
    @State private var map = ""
    @State private var router = ""
    @State private var gps = ""
    @State private var highways = false
    @State private var tolls = false
    @State private var ferries = false
    @State private var busy = false
    @State private var message = ""

    private var changes: [String: Any] {
        guard let original else { return [:] }
        var result: [String: Any] = [:]
        if map != original.mapProvider { result["mapProvider"] = map }
        if router != original.routeProvider { result["routeProvider"] = router }
        if gps != original.gpsSource { result["gpsSource"] = gps }
        if highways != original.avoidHighways { result["avoidHighways"] = highways }
        if tolls != original.avoidTolls { result["avoidTolls"] = tolls }
        if ferries != original.avoidFerries { result["avoidFerries"] = ferries }
        return result
    }

    var body: some View {
        Form {
            if let original {
                Section("On your comma") {
                    LabeledContent("Navigation", value: original.enabled ? "Enabled" : "Disabled")
                    LabeledContent("Internet", value: (original.network ?? "unknown").capitalized)
                    LabeledContent("Mapbox key", value: original.hasKey ? "Configured" : "Missing")
                    LabeledContent("Google key", value: original.hasGoogleKey ? "Configured" : "Missing")
                }
                Section {
                    providerPicker("Map provider", selection: $map)
                    Picker("Directions provider", selection: $router) {
                        Text("Mapbox").tag("mapbox")
                        Text("Google Routes").tag("google")
                    }
                    if router == "google" {
                        Text("Your comma requests a traffic-aware route from Google. If Google can’t supply it, the comma tries Mapbox.").font(.footnote)
                        if !original.hasGoogleKey || !original.hasKey {
                            Text("Set up both the Google Routes API key and the Mapbox key in Galaxy on your comma.").font(.footnote)
                        }
                        if original.routeProvider == "google", let failure = original.googleRoutes?.failure, !failure.isEmpty {
                            LabeledContent("Last Google routing issue", value: failure)
                        }
                        if phoneOnly {
                            Text("Turn off “Use iPhone-only directions” in Navigation settings to use this provider for your next trip.").font(.footnote)
                        }
                    }
                    Picker("GPS source", selection: $gps) {
                        Text("Comma with phone backup").tag("backup")
                        Text("Comma only").tag("comma")
                        Text("Phone").tag("phone")
                    }
                } header: { Text("Providers and location") } footer: {
                    Text("Configure provider keys in Galaxy on your comma. Phone GPS requires Share phone location in the app.")
                }
                Section("Roads to avoid") {
                    Toggle("Highways", isOn: $highways)
                    Toggle("Toll roads", isOn: $tolls)
                    Toggle("Ferries", isOn: $ferries)
                }
                Button("Save to comma") { Task { await update(save: true) } }
                    .disabled(changes.isEmpty)
            }
            Button("Reload from comma") { Task { await update(save: false) } }
            if busy { ProgressView() }
            if !message.isEmpty { Text(message) }
        }
        .disabled(busy)
        .navigationTitle("Comma navigation")
        .task { await update(save: false) }
    }

    private func providerPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Mapbox").tag("mapbox")
            Text("Google Maps").tag("google")
        }
    }

    @MainActor private func update(save: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let session = connection.session
        do {
            _ = try await connection.ensureDeviceIdentity()
            guard connection.session == session else { throw BridgeError.message("Connection changed. Reload the settings.") }
            var path = "/api/navigation/status"
            var body = Data()
            let patch = changes
            if save {
                guard let original, !patch.isEmpty, session == loadedSession else {
                    throw BridgeError.message("Reload settings from the connected comma.")
                }
                path = "/api/navigation/action"
                body = try JSONSerialization.data(withJSONObject: ["action": "configure", "revision": original.revision, "patch": patch])
            }
            let reply = try await connection.transport.request(path: path, method: save ? "POST" : "GET",
                headers: save ? ["content-type": "application/json"] : [:], body: body)
            guard connection.session == session, reply.status == 200 else {
                throw BridgeError.message("Comma could not confirm the settings. Reload to see its current values.")
            }
            let state = try JSONDecoder().decode(Snapshot.self, from: reply.bodyData)
            guard !save || (state.mapProvider == map && state.routeProvider == router && state.gpsSource == gps &&
                state.avoidHighways == highways && state.avoidTolls == tolls && state.avoidFerries == ferries) else {
                throw BridgeError.message("Comma returned different settings. Reload to review them.")
            }
            original = state
            loadedSession = session
            map = state.mapProvider
            router = state.routeProvider
            gps = state.gpsSource
            highways = state.avoidHighways
            tolls = state.avoidTolls
            ferries = state.avoidFerries
            message = save ? "Comma confirmed your settings." : ""
        } catch {
            original = nil
            message = error.localizedDescription
        }
    }
}
