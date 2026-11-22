import SwiftUI
import MapKit

struct PhoneRoute {
    struct Step {
        var maneuverType: String? = nil
        var modifier: String? = nil
        let instructions: String
        let distance: Double
        let polyline: MKPolyline
    }
    let name: String
    let distance: Double
    let expectedTravelTime: Double
    let polyline: MKPolyline
    let steps: [Step]
}

extension PhoneRoute {
    init(_ route: MKRoute) {
        self.init(name: route.name, distance: route.distance, expectedTravelTime: route.expectedTravelTime,
                  polyline: route.polyline, steps: route.steps.map {
            Step(instructions: $0.instructions, distance: $0.distance, polyline: $0.polyline)
        })
    }

    private struct Response: Decodable {
        struct Geometry: Decodable {
            let coordinates: [[Double]]
            func line() throws -> MKPolyline {
                let points = try coordinates.map { pair -> CLLocationCoordinate2D in
                    guard pair.count >= 2 else { throw URLError(.cannotParseResponse) }
                    let point = CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                    guard CLLocationCoordinate2DIsValid(point) else { throw URLError(.cannotParseResponse) }
                    return point
                }
                guard !points.isEmpty else { throw URLError(.cannotParseResponse) }
                return MKPolyline(coordinates: points, count: points.count)
            }
        }
        struct Leg: Decodable {
            struct Segment: Decodable {
                struct Maneuver: Decodable { let instruction: String; let type: String?; let modifier: String? }
                let geometry: Geometry
                let distance: Double
                let maneuver: Maneuver
            }
            let steps: [Segment]
            let summary: String
        }
        struct Route: Decodable {
            let geometry: Geometry
            let legs: [Leg]
            let distance: Double
            let duration: Double
        }
        let routes: [Route]
    }

    static func mapbox(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       alternatives: Bool, token: String) async throws -> [PhoneRoute] {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.mapbox.com"
        url.path = "/directions/v5/mapbox/driving/\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
        url.queryItems = ["access_token": token, "alternatives": String(alternatives), "steps": "true",
                          "geometries": "geojson", "overview": "full"].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).routes.map { route in
            let segments = route.legs.flatMap(\.steps)
            // Mapbox maneuvers describe the start of each segment. Galaxy announces
            // the turn at its end, so pair each segment with the following maneuver.
            let steps = try zip(segments, segments.dropFirst()).map { current, next in
                Step(maneuverType: next.maneuver.type, modifier: next.maneuver.modifier,
                     instructions: next.maneuver.instruction, distance: current.distance, polyline: try current.geometry.line())
            }
            return PhoneRoute(name: route.legs.map(\.summary).joined(separator: ", "), distance: route.distance,
                             expectedTravelTime: route.duration, polyline: try route.geometry.line(), steps: steps)
        }
    }
}
import CoreLocation
import UIKit

struct NavigationPlace: Identifiable {
    let id = UUID()
    let item: MKMapItem
    var subtitle: String? = nil
    var name: String { item.name ?? "Destination" }
    var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }
    var address: String {
        if let subtitle { return subtitle }
        return [item.placemark.thoroughfare, item.placemark.locality, item.placemark.administrativeArea]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

@MainActor
final class NavigationModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, @preconcurrency MKLocalSearchCompleterDelegate {
    var onEvent: ((String) -> Void)?
    @Published var results: [NavigationPlace] = []
    @Published var destination: NavigationPlace?
    @Published private(set) var plannedStart: NavigationPlace?
    @Published var routes: [PhoneRoute] = []
    @Published var selectedRoute = 0
    @Published var usingComma = false
    @Published var commaPolyline: MKPolyline?
    @Published private(set) var positionDisplayGeneration = 0
    @Published var commaPosition: CLLocationCoordinate2D?
    @Published var commaFeedMessage = ""
    @Published var commaFeedReady = false
    @Published var commaManeuverType = ""
    @Published var commaManeuverModifier = ""
    @Published var navigating = false
    @Published var endingRoute = false
    @Published var busy = false
    @Published var searching = false
    @Published var error = "" { didSet { if oldValue != error { onEvent?(error.isEmpty ? "UI error cleared" : "UI error banner shown (see preceding action)") } } }
    @Published var notice = ""
    @Published var instruction = ""
    @Published var distanceToTurn: CLLocationDistance = 0
    @Published var remainingDistance: CLLocationDistance = 0
    @Published var remainingTime: TimeInterval = 0
    @Published var location: CLLocation?
    @Published var locationMessage = "Allow location to preview a route."
    @Published private(set) var overviewRevision = 0
    @Published var followsUser = true
    @Published var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @Published var sendToComma = true { didSet { if oldValue != sendToComma { onEvent?("Send to comma changed: \(sendToComma)") } } }
    private let manager = CLLocationManager()
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var searchMessage = ""
    private var completer: MKLocalSearchCompleter?
    private var searchRequest: MKLocalSearch?
    private var directions: MKDirections?
    private var revision = UUID()
    private var searchRevision = UUID()
    private var foreground = false
    private var recalculating = false
    private var lastCalculation = Date.distantPast
    private var offRouteSamples = 0
    private var stepIndex = 0
    private var phoneTurn = false

    private func isTurn(type: String?, modifier: String?, instruction: String) -> Bool {
        if let type = type?.lowercased(), !type.isEmpty {
            switch type {
            case "turn", "fork", "merge", "on ramp", "off ramp", "roundabout", "rotary", "roundabout turn", "exit rotary", "exit roundabout":
                return modifier?.lowercased() != "straight"
            case "continue", "end of road":
                return ["right", "left", "sharp right", "sharp left", "slight right", "slight left", "uturn"].contains(modifier?.lowercased() ?? "")
            default: return false
            }
        }
        let words = instruction.lowercased().split { !$0.isLetter }
        return words.contains { ["left", "right", "roundabout", "rotary", "uturn", "exit", "ramp"].contains(String($0)) }
    }

    func followPitch(cruising: Double, speed: Double) -> Double {
        let upcoming = usingComma ? commaFeedReady && isTurn(type: commaManeuverType, modifier: commaManeuverModifier, instruction: instruction) : phoneTurn
        return NavigationMapMotion.followPitch(cruising: cruising, speed: speed,
            turnDistance: navigating && upcoming ? distanceToTurn : nil)
    }
    private var commandRunning = false
    private var commandGeneration = UUID()
#if targetEnvironment(simulator)
    func refreshPreviewPosition() { lastCommaSample = Date(); commaPositionSampleDate = Date(); locationMessage = "" }
#endif
    var commaHeading: Double { commaBearing }
    private(set) var commaPositionSampleDate = Date.distantPast
    private var followCameraDistance: CLLocationDistance {
        NavigationMapMotion.cameraDistance(speed: max(0, goodLocation?.speed ?? 0),
            distanceToTurn: navigating ? distanceToTurn : 0)
    }
    private var commaBearing: Double = 0
    private var lastCommaSample = Date.distantPast
    private var guidanceMaxAge: TimeInterval = 4
    private var cachedCommaPolyline: MKPolyline?
    private var commaRouteVersion: String?
    private var commaIdentity: String?
    private var commaDestination: CLLocationCoordinate2D?
    var route: PhoneRoute? { routes.indices.contains(selectedRoute) ? routes[selectedRoute] : nil }
    var goodLocation: CLLocation? {
        guard let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50,
              abs(location.timestamp.timeIntervalSinceNow) < 15 else { return nil }
        return location
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }
    func setActive(_ active: Bool) {
        foreground = active
        if active, [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) { manager.startUpdatingLocation() }
        if !active {
            if usingComma { clearCommaDisplay("Reconnecting to comma…") }
            manager.stopUpdatingLocation()
            directions?.cancel(); cancelPlaceSearch()
            revision = UUID()
            searching = false; if !commandRunning { busy = false }; recalculating = false
        }
    }
    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: if foreground { manager.startUpdatingLocation() }
        default: locationMessage = "Enable location for StarPilot Nav in iPhone Settings."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { requestLocationIfAuthorized() }
    private func requestLocationIfAuthorized() {
        if [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus), foreground { manager.startUpdatingLocation() }
        else if [.denied, .restricted].contains(manager.authorizationStatus) { locationMessage = "Enable location for StarPilot Nav in iPhone Settings." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onEvent?("Phone location failed: \(LANTransport.failureCode(error))")
        locationMessage = "Waiting for a reliable GPS location."
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard foreground, let latest = locations.last else { return }
        location = latest
        guard let fresh = goodLocation else { locationMessage = "Waiting for a reliable GPS location."; return }
        locationMessage = ""
        guard navigating, !usingComma, let route else { return }
        updateProgress(route, at: fresh)
        if followsUser {
            withAnimation(.linear(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.8)) {
                camera = .camera(MapCamera(centerCoordinate: fresh.coordinate, distance: followCameraDistance,
                    heading: fresh.course >= 0 ? fresh.course : camera.camera?.heading ?? 0,
                    pitch: followPitch(cruising: 62, speed: fresh.speed)))
            }
        }
        let deviation = distanceFromRoute(fresh.coordinate, polyline: route.polyline)
        offRouteSamples = deviation > max(60, fresh.horizontalAccuracy * 2) ? offRouteSamples + 1 : 0
        if !recalculating, Date().timeIntervalSince(lastCalculation) > 30,
           offRouteSamples >= 3 || Date().timeIntervalSince(lastCalculation) > 120 {
            Task { await calculateRoutes(refresh: true) }
        }
    }
    func cancelPlaceSearch() {
        searchRevision = UUID()
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        searchRequest?.cancel()
        searchRequest = nil
        suggestions = []
        results = []
        searching = false
        searchMessage = ""
    }

    func suggest(_ query: String, choosingStart: Bool) {
        cancelPlaceSearch()
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [NavigationPlace(
                item: MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38))),
                subtitle: "Test address")]
            if let item = results.first?.item { item.name = "Test Place" }
            return
        }
        #endif
        let service = MKLocalSearchCompleter()
        service.resultTypes = [.address, .pointOfInterest]
        let nearby = location.flatMap { fix in
            fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 5000
                && abs(fix.timestamp.timeIntervalSinceNow) <= 900 ? fix.coordinate : nil
        }
        let center = choosingStart ? (nearby ?? destination?.coordinate) : (plannedStart?.coordinate ?? nearby)
        if let center {
            service.region = MKCoordinateRegion(center: center, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        completer = service
        service.delegate = self
        searching = true
        service.queryFragment = cleaned
    }

    func completerDidUpdateResults(_ service: MKLocalSearchCompleter) {
        guard service === completer else { return }
        suggestions = Array(service.results.prefix(12))
        if suggestions.isEmpty { searchFullText(service) }
        else { searching = false }
    }

    func completer(_ service: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard service === completer else { return }
        searchFullText(service)
    }

    private func searchFullText(_ service: MKLocalSearchCompleter) {
        service.delegate = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = service.queryFragment
        request.region = service.region
        let token = searchRevision
        Task {
            guard searchRevision == token else { return }
            let items = await findPlaces(request, token: token)
            guard searchRevision == token else { return }
            results = items.map { NavigationPlace(item: $0) }
        }
    }

    func resolve(_ suggestion: MKLocalSearchCompletion) async -> NavigationPlace? {
        guard suggestions.contains(where: { $0 === suggestion }), !searching else { return nil }
        let token = searchRevision
        let items = await findPlaces(MKLocalSearch.Request(completion: suggestion), token: token)
        guard searchRevision == token, let item = items.first else { return nil }
        return NavigationPlace(item: item, subtitle: suggestion.subtitle.isEmpty ? nil : suggestion.subtitle)
    }

    private func findPlaces(_ request: MKLocalSearch.Request, token: UUID) async -> [MKMapItem] {
        searching = true
        searchMessage = ""
        let search = MKLocalSearch(request: request)
        searchRequest = search
        defer { if searchRevision == token { searching = false; searchRequest = nil } }
        do {
            let response = try await search.start()
            guard searchRevision == token else { return [] }
            if response.mapItems.isEmpty { searchMessage = "No places found. Try a more specific search." }
            return Array(response.mapItems.prefix(12))
        } catch {
            if searchRevision == token { searchMessage = "Couldn’t find this place. Try again or refine your search." }
            return []
        }
    }
    func select(_ place: NavigationPlace) async {
        onEvent?("Destination selected; busy: \(busy); navigating: \(navigating)")
        guard !navigating, !busy else { onEvent?("Destination selection blocked by current state"); return }
        plannedStart = nil
        destination = place; routes = []; selectedRoute = 0; notice = ""; error = ""
        camera = .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500))
        if !sendToComma { await calculateRoutes(refresh: false) }
    }
    func chooseRoute(_ index: Int) {
        guard !navigating, routes.indices.contains(index) else { return }
        onEvent?("Route alternative selected: \(index + 1)")
        selectedRoute = index
        camera = .rect(routes[index].polyline.boundingMapRect)
    }
    func selectGuidanceSource(comma: Bool) async {
        guard !busy, !navigating, comma != sendToComma else { return }
        sendToComma = comma; error = ""
        if comma, plannedStart != nil { plannedStart = nil; routes = []; selectedRoute = 0 }
        if !comma && routes.isEmpty { await calculateRoutes(refresh: false) }
    }
    func preview(from place: NavigationPlace?) async {
        guard !navigating, !commandRunning, destination != nil else { return }
        revision = UUID()
        directions?.cancel()
        recalculating = false
        busy = false
        plannedStart = place
        sendToComma = false
        routes = []; selectedRoute = 0
        error = ""; notice = ""; locationMessage = ""
        await calculateRoutes(refresh: false)
    }
    func calculateRoutes(refresh: Bool) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        onEvent?("Route calculation requested; refresh: \(refresh); destination: \(destination != nil); active: \(foreground); calculating: \(recalculating)")
        guard let destination, foreground, !sendToComma, !commandRunning, !recalculating else { onEvent?("Route calculation skipped by current state"); return }
        let token = UUID(); revision = token
        directions?.cancel()
        recalculating = true
        if !refresh { busy = true }
        defer {
            if revision == token { recalculating = false; busy = false }
        }
        let previewOrigin = plannedStart.map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        if previewOrigin == nil && goodLocation == nil {
            error = ""
            locationMessage = "Getting your current location…"
            manager.stopUpdatingLocation()
            requestLocation()
            for _ in 0..<16 {
                guard foreground, revision == token, !Task.isCancelled else { return }
                if goodLocation != nil { break }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        guard foreground, revision == token, !Task.isCancelled else { return }
        guard let origin = previewOrigin ?? goodLocation else {
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                error = "Enable location for StarPilot Nav in iPhone Settings."
            } else if manager.accuracyAuthorization == .reducedAccuracy {
                error = "Enable Precise Location for StarPilot Nav in iPhone Settings."
            } else {
                error = "Still waiting for an accurate location. Try again with a clearer view of the sky."
            }
            onEvent?("Route calculation blocked: no fresh accurate phone location; authorization: \(manager.authorizationStatus.rawValue); precision: \(manager.accuracyAuthorization.rawValue)")
            locationMessage = error
            return
        }
        locationMessage = ""
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = destination.item
        request.transportType = .automobile
        request.requestsAlternateRoutes = !refresh
        lastCalculation = Date()
        do {
            let choices: [PhoneRoute]
            if let accessToken = NavigationMapPreference.activeToken {
                choices = try await PhoneRoute.mapbox(from: origin.coordinate, to: destination.coordinate,
                                                      alternatives: !refresh, token: accessToken)
            } else {
                let service = MKDirections(request: request)
                directions = service
                choices = try await service.calculate().routes.map(PhoneRoute.init)
            }
            guard foreground, revision == token, !Task.isCancelled else { return }
            guard !choices.isEmpty else { throw BridgeError.message("No driving route found.") }
            onEvent?("Route calculation completed: \(choices.count) alternatives")
            routes = Array(choices.prefix(3)); selectedRoute = 0; stepIndex = 0
            offRouteSamples = 0; error = ""
            if !navigating { camera = .rect(routes[0].polyline.boundingMapRect) }
            updateProgress(routes[0], at: origin)
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            onEvent?("Route calculation failed: \(LANTransport.failureCode(error))")
            self.error = refresh ? "Couldn’t refresh the phone route. Keeping the previous route." : "Couldn’t calculate a driving route. Check internet and location."
        }
    }

    func start(connection: CommaConnection) async {
        onEvent?("Go tapped; comma: \(sendToComma); connected: \(connection.connected); busy: \(busy); navigating: \(navigating); destination: \(destination != nil); route: \(route != nil)")
        guard !busy, !navigating, let destination else { onEvent?("Go blocked by current UI state"); return }
        if plannedStart != nil {
            await preview(from: nil)
            return
        }
        let useComma = sendToComma
        guard useComma || route != nil else { error = "Get directions on iPhone before starting this route."; return }
        guard useComma || goodLocation != nil else {
            requestLocation()
            onEvent?("Go blocked: no fresh accurate phone location")
            error = "Refreshing your location. Tap Go again in a moment."
            return
        }
        guard !useComma || connection.connected else { onEvent?("Go blocked: comma disconnected"); error = "Connect to comma or choose iPhone for directions."; return }
        let generation = commandGeneration
        busy = true; commandRunning = true; connection.busy = true
        defer { if generation == commandGeneration { busy = false; commandRunning = false; connection.busy = false } }
        error = ""; notice = ""; commaDestination = nil; commaIdentity = nil
        if useComma {
            let identity: String
            do { identity = try await connection.ensureDeviceIdentity(); guard generation == commandGeneration else { return } }
            catch {
                guard generation == commandGeneration else { return }
                onEvent?("Go blocked: identity verification failed; \(LANTransport.failureCode(error))")
                self.error = "No destination sent. \(error.localizedDescription)"
                return
            }
            var sending = false
            do {
                if !connection.nativeNavigation {
                    let feed = try await connection.navigationSnapshot()
                    guard generation == commandGeneration else { return }
                    guard feed.ready else { throw BridgeError.message(feed.error ?? "Comma’s navigation reader is starting. Try again in a moment.") }
                }
                guard connection.deviceIdentity == identity else { throw BridgeError.message("Comma connection changed. Try again.") }
                let destinationPayload = try NavigationDestination(name: destination.name,
                    latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude)
                onEvent?("Destination send requested (details omitted)")
                _ = try await connection.navigation(.start(destinationPayload)) { sending = true }
                guard generation == commandGeneration else { return }
                onEvent?("Destination confirmed by comma")
                commaDestination = destination.coordinate; commaIdentity = identity
                notice = ""
            } catch {
                guard generation == commandGeneration else { return }
                onEvent?("Go failed; send phase: \(sending); \(LANTransport.failureCode(error))")
                self.error = sending ? "Comma did not confirm the destination. Check its screen before retrying. \(error.localizedDescription)" : "No destination sent. \(error.localizedDescription)"
                return
            }
        }
        usingComma = useComma
        positionDisplayGeneration += 1; commaPolyline = nil; cachedCommaPolyline = nil; commaPosition = nil; commaRouteVersion = nil; commaFeedReady = false
        commaFeedMessage = usingComma ? "Waiting for comma’s route…" : ""
        if usingComma {
            instruction = "Waiting for comma’s route"; distanceToTurn = 0; remainingTime = 0; remainingDistance = 0
        }
        onEvent?("Navigation started; comma: \(usingComma)")
        navigating = true; stepIndex = 0
        if !usingComma, let location = goodLocation, let route { updateProgress(route, at: location) }
    }

    func end(connection: CommaConnection, phoneOnly: Bool = false) async {
        onEvent?("End tapped; phone only: \(phoneOnly); busy: \(busy)")
        guard !busy else { onEvent?("End blocked: busy"); return }
        let generation = commandGeneration
        endingRoute = true
        busy = true; commandRunning = true; connection.busy = true
        defer { if generation == commandGeneration { endingRoute = false; busy = false; commandRunning = false; connection.busy = false } }
        if !phoneOnly, let expected = commaDestination {
            guard commaIdentity == connection.deviceIdentity else { error = "A different comma is paired. Use End on phone only."; return }
            do {
                let session = connection.session
                let data = try await connection.navigation(.read)
                guard generation == commandGeneration else { return }
                if let current = try NavigationCommand.activeDestination(in: data) {
                    let previous = try NavigationDestination(name: "Previous destination", latitude: expected.latitude, longitude: expected.longitude)
                    guard current.matches(previous) else {
                        error = "Comma has a different destination now. Use End on phone only to leave it unchanged."
                        return
                    }
                    guard session == connection.session else { throw BridgeError.message("Connection changed.") }
                    _ = try await connection.navigation(.end)
                guard generation == commandGeneration else { return }
                }
            } catch {
                guard generation == commandGeneration else { return }
                onEvent?("End failed: \(LANTransport.failureCode(error))")
                self.error = "Couldn’t confirm End Route on comma. Check its screen or choose End on phone only."
                return
            }
        }
        directions?.cancel(); revision = UUID(); recalculating = false
        usingComma = false; positionDisplayGeneration += 1; commaPolyline = nil; cachedCommaPolyline = nil; commaPosition = nil; commaRouteVersion = nil; commaFeedReady = false
        navigating = false; routes = []; plannedStart = nil; destination = nil; commaDestination = nil; commaIdentity = nil
        onEvent?("Navigation ended; phone only: \(phoneOnly)")
        error = ""; instruction = ""; notice = phoneOnly ? "Phone route ended. Comma was left unchanged." : "Route ended."
        camera = .userLocation(fallback: .automatic)
    }

    func monitorComma(connection: CommaConnection, session: String) async {
        while !Task.isCancelled, connection.session == session, foreground, navigating, usingComma {
            if commandRunning || connection.setupInProgress {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            do {
                let revision = self.revision
                // A route handoff invalidates the adapter's identity cache. Reverify
                // before accepting guidance, rather than comparing against a stale nil.
                let identity = try await connection.ensureDeviceIdentity()
                guard !Task.isCancelled, connection.session == session, navigating, usingComma, self.revision == revision else { return }
                guard commaIdentity == identity else {
                    clearCommaDisplay("Paired comma changed. Check the connection.", discardRoute: true)
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                let requestedAt = Date()
                let snapshot = try await connection.navigationSnapshot(version: commaRouteVersion)
                onEvent?("Guidance response; elapsed: \(String(format: "%.3f", Date().timeIntervalSince(requestedAt)))s; state: \(snapshot.status); instruction: \(snapshot.instruction != nil); route points: \(snapshot.routePoints?.count ?? 0); cached route: \(cachedCommaPolyline != nil); version matches: \(commaRouteVersion == snapshot.routeVersion)")
                guard !Task.isCancelled, connection.session == session, navigating, usingComma, self.revision == revision else { onEvent?("Guidance response ignored: navigation changed or cancelled"); return }
                guard !commandRunning else { onEvent?("Guidance ignored: route command in progress"); continue }
                guard commaIdentity == connection.deviceIdentity else {
                    clearCommaDisplay("Paired comma changed. Check the connection.", discardRoute: true)
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                guard let expected = commaDestination, let current = snapshot.destination,
                      abs(current.latitude - expected.latitude) < 0.000001,
                      abs(current.longitude - expected.longitude) < 0.000001 else {
                    clearCommaDisplay(snapshot.status == "inactive" ? "Comma navigation has ended." : "Comma’s destination changed. Check its screen.", discardRoute: true)
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                guard snapshot.status == "active", let instructions = snapshot.instruction else {
                    if snapshot.error?.isEmpty == false { clearCommaDisplay(snapshot.error!) }
                    else if snapshot.status == "waiting" {
                        let parked = await connection.commaIsParked()
                        guard !Task.isCancelled, connection.session == session, navigating, self.revision == revision else { return }
                        if parked == true {
                            clearCommaDisplay("Destination saved on comma. Waiting for route guidance.")
                            instruction = "Waiting for guidance"
                        } else { clearCommaDisplay("Waiting for fresh navigation from comma…") }
                    } else { clearCommaDisplay("Waiting for fresh navigation from comma…") }
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                if let points = snapshot.routePoints {
                    guard points.count >= 2 else { throw NavigationContractError.invalidResponse }
                    let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    cachedCommaPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    commaRouteVersion = snapshot.routeVersion
                } else if let encoded = snapshot.polyline6 {
                    let points = try RoutePolyline.decode(encoded)
                    guard points.count >= 2 else { throw NavigationContractError.invalidResponse }
                    let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    cachedCommaPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    commaRouteVersion = snapshot.routeVersion
                }
                guard cachedCommaPolyline != nil, commaRouteVersion == snapshot.routeVersion else {
                    clearCommaDisplay("Waiting for comma’s updated route…", discardRoute: true)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    continue
                }
                // Time in the phone's outbound queue precedes sampling on comma.
                let sampledAfter = max(requestedAt, min(snapshot.bluetoothDispatchDate ?? requestedAt, Date()))
                guidanceMaxAge = connection.nativeNavigation ? NativeNavigationAPI.guidanceDisplayMaxAge : 4
                let elapsed = Date().timeIntervalSince(sampledAfter)
                let remaining = connection.nativeNavigation
                    ? NativeNavigationAPI.guidanceRemaining(ageUpperBound: snapshot.ageSeconds, elapsed: elapsed)
                    : max(0, guidanceMaxAge - (snapshot.ageSeconds ?? guidanceMaxAge) - elapsed)
                guard let age = snapshot.ageSeconds, remaining > 0 else {
                    onEvent?("Guidance rejected: stale; server age: \(snapshot.ageSeconds ?? -1)s; request elapsed: \(String(format: "%.3f", Date().timeIntervalSince(sampledAfter)))s; limit: \(guidanceMaxAge)s")
                    commaFeedReady = false; commaPolyline = nil; commaPosition = nil
                    commaFeedMessage = "Waiting for fresh navigation from comma…"
                    instruction = "Navigation unavailable"; distanceToTurn = 0; remainingDistance = 0; remainingTime = 0
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    continue
                }
                onEvent?("Guidance accepted; remaining freshness: \(String(format: "%.3f", guidanceMaxAge - age - Date().timeIntervalSince(sampledAfter)))s")
                commaPolyline = cachedCommaPolyline
                lastCommaSample = sampledAfter.addingTimeInterval(-age)
                instruction = [instructions.primary, instructions.secondary].filter { !$0.isEmpty }.joined(separator: "\n")
                distanceToTurn = instructions.distance
                remainingDistance = instructions.distanceRemaining; remainingTime = instructions.timeRemaining
                commaManeuverType = instructions.type; commaManeuverModifier = instructions.modifier
                commaFeedReady = true; commaFeedMessage = ""; error = ""
                if let position = snapshot.position, snapshot.positionValidForSeconds == nil || snapshot.positionValidForSeconds! > Date().timeIntervalSince(sampledAfter) {
                    commaPositionExpires = snapshot.positionValidForSeconds.map { sampledAfter.addingTimeInterval($0) }
                    commaPositionSampleDate = sampledAfter
                    if let bearing = position.bearing { commaBearing = bearing }
                    commaPosition = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                } else { commaPosition = nil }
            } catch {
                onEvent?("Guidance request failed: \(LANTransport.failureCode(error)); cancelled: \(Task.isCancelled)")
                if Task.isCancelled || connection.session != session { return }
                clearCommaDisplay(error.localizedDescription)
                // An unavailable connection cannot recover through faster status polls.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            let delay = connection.transport.localRefreshDelay ?? (connection.nativeNavigation ? 0.5 : 2)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }
    private var commaPositionExpires: Date?
    func checkCommaFreshness() {
        if let expires = commaPositionExpires, Date() >= expires { commaPosition = nil }
        if usingComma, commaFeedReady, Date().timeIntervalSince(lastCommaSample) >= guidanceMaxAge {
            clearCommaDisplay("Comma navigation is stale. Reconnecting…")
        }
    }
    private func clearCommaDisplay(_ message: String, discardRoute: Bool = false) {
        onEvent?("Guidance cleared; reason: \(message); discard route: \(discardRoute); was ready: \(commaFeedReady); cached route: \(cachedCommaPolyline != nil); last sample age: \(lastCommaSample == .distantPast ? -1 : Date().timeIntervalSince(lastCommaSample))s")
        commaFeedReady = false; commaPolyline = nil; commaPosition = nil
        if discardRoute { positionDisplayGeneration += 1; commaRouteVersion = nil; cachedCommaPolyline = nil }
        commaFeedMessage = message
        instruction = "Navigation unavailable"; distanceToTurn = 0; remainingDistance = 0; remainingTime = 0
    }

    var diagnosticSummary: String {
        "Navigating: \(navigating); comma: \(usingComma); busy: \(busy); foreground: \(foreground)\nGuidance ready: \(commaFeedReady); sample upper-bound age: \(lastCommaSample == .distantPast ? -1 : Date().timeIntervalSince(lastCommaSample)); max age: \(guidanceMaxAge)s\nRoute cached: \(cachedCommaPolyline != nil); displayed: \(commaPolyline != nil); position displayed: \(commaPosition != nil); destination selected: \(destination != nil)\nUI error present: \(!error.isEmpty); follows location: \(followsUser)"
    }

    func followLocation() {
        onEvent?("Recenter tapped")
        followsUser = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--navigation-motion") { return }
        #endif
        requestLocation()
        if usingComma {
            if let coordinate = commaPosition {
                withAnimation(.easeInOut(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.4)) {
                    camera = .camera(MapCamera(centerCoordinate: coordinate, distance: followCameraDistance,
                        heading: commaBearing, pitch: followPitch(cruising: 62, speed: 0)))
                }
            }
            return
        }
        if navigating, let location = goodLocation {
            camera = .camera(MapCamera(centerCoordinate: location.coordinate, distance: followCameraDistance,
                heading: location.course >= 0 ? location.course : camera.camera?.heading ?? 0,
                pitch: followPitch(cruising: 62, speed: location.speed)))
        } else { camera = .userLocation(fallback: .automatic) }
    }
    func showOverview() {
        onEvent?("Route overview tapped")
        overviewRevision += 1
        followsUser = false
        if usingComma, let polyline = commaPolyline { camera = .rect(polyline.boundingMapRect) }
        else if let route { camera = .rect(route.polyline.boundingMapRect) }
    }

    func resetLocalNavigation() {
        commandGeneration = UUID(); revision = UUID()
        directions?.cancel(); directions = nil
        cancelPlaceSearch()
        commandRunning = false; endingRoute = false; busy = false; searching = false; recalculating = false
        navigating = false; usingComma = false
        results = []; routes = []; plannedStart = nil; destination = nil; selectedRoute = 0
        commaDestination = nil; commaIdentity = nil; cachedCommaPolyline = nil
        positionDisplayGeneration += 1; commaPolyline = nil; commaPosition = nil; commaRouteVersion = nil
        commaFeedReady = false; commaFeedMessage = ""
        instruction = ""; distanceToTurn = 0; remainingTime = 0; remainingDistance = 0
        error = ""; notice = "Navigation reset."; followsUser = true
        camera = .userLocation(fallback: .automatic)
        onEvent?("Reset: local routes, searches, guidance and pending command results cleared")
    }

    func clearPreview() {
        onEvent?("Destination preview cleared")
        guard !busy, !navigating else { return }
        directions?.cancel(); revision = UUID(); recalculating = false
        routes = []; plannedStart = nil; destination = nil; error = ""
        camera = .userLocation(fallback: .automatic)
    }


    #if DEBUG
    func runMapMotionTest() async {
        let start = CLLocationCoordinate2D(latitude: 43.451, longitude: -80.489)
        let end = CLLocationCoordinate2D(latitude: 43.48, longitude: -80.489)
        let coordinates = [start, end]
        commaPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        navigating = true; usingComma = true; followsUser = true
        instruction = "Test road"; distanceToTurn = 14000
        remainingDistance = 18000; remainingTime = 28 * 60
        let item = MKMapItem(placemark: MKPlacemark(coordinate: end))
        item.name = "Map test · sample data"
        destination = NavigationPlace(item: item)
        let expires = ProcessInfo.processInfo.arguments.contains("--motion-expiry")
        for index in 0..<(expires ? 3 : 30) {
            guard !Task.isCancelled else { return }
            lastCommaSample = Date(); commaPositionSampleDate = Date()
            commaBearing = index == 0 ? 359 : 1
            commaPosition = CLLocationCoordinate2D(latitude: start.latitude + Double(index) * 0.0004,
                longitude: start.longitude)
            commaFeedReady = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        checkCommaFreshness()
    }
    #endif

    private func updateProgress(_ route: PhoneRoute, at location: CLLocation) {
        let steps = route.steps.filter { !$0.instructions.isEmpty && $0.polyline.pointCount > 0 }
        guard !steps.isEmpty else { phoneTurn = false; instruction = "Continue to your destination"; return }
        stepIndex = min(stepIndex, steps.count - 1)
        while stepIndex < steps.count - 1 {
            let step = steps[stepIndex]
            let end = step.polyline.points()[step.polyline.pointCount - 1].coordinate
            let distance = location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            if distance > 35 { break }
            stepIndex += 1
        }
        let current = steps[stepIndex]
        phoneTurn = isTurn(type: current.maneuverType, modifier: current.modifier, instruction: current.instructions)
        let end = current.polyline.points()[current.polyline.pointCount - 1].coordinate
        distanceToTurn = location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        instruction = current.instructions
        remainingDistance = max(0, distanceToTurn + steps.dropFirst(stepIndex + 1).reduce(0) { $0 + $1.distance })
        let fraction = route.distance > 0 ? min(1, remainingDistance / route.distance) : 0
        remainingTime = route.expectedTravelTime * fraction
        if let destination, location.distance(from: CLLocation(latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude)) < 40 {
            instruction = "You’re near your destination"
            phoneTurn = false
        }
    }
    private func distanceFromRoute(_ coordinate: CLLocationCoordinate2D, polyline: MKPolyline) -> Double {
        let p = MKMapPoint(coordinate); let points = polyline.points()
        guard polyline.pointCount > 1 else { return .infinity }
        var nearest = Double.infinity
        for i in 1..<polyline.pointCount {
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator)) : 0
            nearest = min(nearest, p.distance(to: MKMapPoint(x: a.x + fraction * dx, y: a.y + fraction * dy)))
        }
        return nearest
    }
}
