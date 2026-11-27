import SwiftUI
import MapKit

struct NavigationMapLayer: View {
    @ObservedObject var navigation: NavigationModel
    @AppStorage("navigation.appleStyle") private var appleStyle = GalaxyAppleMap.streets
    let markerPerspective: DriveMarkerPerspective
    let headerBottom: CGFloat
    let tripFrame: CGRect
    var plannerInsets = EdgeInsets()
    @AppStorage(NavigationMapPreference.enabledKey) private var useMapbox = true
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""

    var body: some View {
        Group {
            if useMapbox && token.hasPrefix("pk.") {
                MapboxDriveMap(navigation: navigation, token: token, markerPerspective: markerPerspective, tripFrame: tripFrame, headerBottom: headerBottom, plannerInsets: plannerInsets)
                    .ignoresSafeArea(.container, edges: navigation.navigating ? .top : [])
                    .id(token)
            } else if navigation.navigating && navigation.usingComma {
                CommaFollowingMap(navigation: navigation, bottomInset: tripFrame.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                Map(position: $navigation.camera) {
                    UserAnnotation()
                    if let start = navigation.plannedStart {
                        Marker(start.name, systemImage: "flag.fill", coordinate: start.coordinate).tint(StarPilotTheme.accent)
                    }
                    ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                        MapPolyline(route.polyline).stroke(index == navigation.selectedRoute ? Color(uiColor: StarPilotTheme.routePurple) : Color.gray.opacity(0.5),
                            style: StrokeStyle(lineWidth: index == navigation.selectedRoute ? 8 : 5, lineCap: .round))
                    }
                    if let destination = navigation.destination {
                        Marker(destination.name, coordinate: destination.coordinate).tint(.red)
                    }
                }
                .mapStyle(appleStyle.style)
                .mapControls { MapCompass() }
                .safeAreaPadding(.leading, plannerInsets.leading)
                .safeAreaPadding(.bottom, plannerInsets.bottom)
                .onChange(of: navigation.camera.positionedByUser) { _, moved in
                    if moved { navigation.followsUser = false }
                }
            }
        }
    }
}

struct TripBarFollowMarker: View {
    let markerPerspective: DriveMarkerPerspective
    @ObservedObject var navigation: NavigationModel
    @AppStorage(NavigationMapPreference.enabledKey) private var useMapbox = true
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""

    var body: some View {
        if useMapbox && token.hasPrefix("pk.") && navigation.navigating && navigation.followsUser {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let fresh = navigation.usingComma
                    ? navigation.commaFeedReady && navigation.commaPosition != nil &&
                        clock.date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4
                    : navigation.goodLocation != nil
                if fresh {
                    DrivePositionMarker(perspective: markerPerspective, following: true, comma: navigation.usingComma)
                        .offset(y: -DrivePositionMarker.barClearance - DrivePositionMarker.diameter)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct QueuedPlaceStatus: View {
    @ObservedObject private var inbox = ShareInbox.shared
    var body: some View {
        if let pending = inbox.waiting, let place = pending.place {
            HStack {
                Label("Queued for comma: \(place.name)", systemImage: "clock")
                Spacer()
                Button("Cancel") { inbox.cancelQueuedPlace(pending.id) }
            }.font(.subheadline)
        }
    }
}

struct RouteStartAction: View {
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var connection: CommaConnection
    @ObservedObject private var inbox = ShareInbox.shared
    @AppStorage("navigation.phoneRouter") private var router = "Automatic"
    @AppStorage(NavigationMapPreference.tokenKey) private var mapToken = ""
    @State private var navigatorTrip: NavigatorTrip?
    private struct NavigatorTrip: Identifiable {
        let id = UUID()
        let origin: CLLocationCoordinate2D
        let destination: CLLocationCoordinate2D
        let token: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if navigation.sendToComma {
                let queued = inbox.waiting?.place
                let samePlace = queued != nil && queued?.latitude == navigation.destination?.coordinate.latitude
                    && queued?.longitude == navigation.destination?.coordinate.longitude
                Text("Your comma calculates route options after it receives this destination.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    if connection.connected {
                        if let pending = inbox.waiting { inbox.cancelQueuedPlace(pending.id) }
                        Task { await navigation.start(connection: connection) }
                    } else if let place = navigation.destination { inbox.queuePlace(place) }
                } label: {
                    Text(navigation.busy ? "Sending destination…" : samePlace ? "Queued for comma" :
                            connection.connected ? "Send to comma" : queued == nil ? "Send when connected" : "Replace queued destination")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .disabled(navigation.busy || samePlace)
            } else if let external = ExternalNavigator(rawValue: router), let place = navigation.destination,
                      let url = external.directions(to: place.coordinate) {
                Link("Open destination in " + external.rawValue, destination: url)
            } else if router == "Mapbox Navigator" && navigation.plannedStart == nil {
                Button("Start Mapbox Navigator on iPhone") {
                    guard let place = navigation.destination else { return }
                    guard mapToken.hasPrefix("pk.") else {
                        navigation.error = "Save a Mapbox public token in Navigation settings."
                        return
                    }
                    guard let origin = navigation.goodLocation else {
                        navigation.requestLocation()
                        navigation.error = "Waiting for an accurate current location."
                        return
                    }
                    navigatorTrip = NavigatorTrip(origin: origin.coordinate, destination: place.coordinate, token: mapToken)
                }
                .fullScreenCover(item: $navigatorTrip) { trip in
                    MapboxNavigatorScreen(origin: trip.origin, destination: trip.destination, token: trip.token)
                }
            } else if navigation.busy {
                ProgressView("Getting directions…")
            } else if navigation.routes.isEmpty {
                Button("Get directions") { Task { await navigation.calculateRoutes(refresh: false) } }
            } else if navigation.plannedStart == nil, let route = navigation.route {
                Text(route.startSummary(sharing: false))
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Start Route") {
                    Task { await navigation.start(connection: connection) }
                }
            } else {
                Text("Preview from your chosen starting point. Use your current location to start guidance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct ParkedPhoneRoutePreview: View {
    let bodyData: Data
    @ObservedObject var connection: CommaConnection
    @State private var loading = false
    @State private var message = ""
    @State private var preview: Reply?
    private struct Reply: Decodable, Identifiable {
        struct Point: Decodable { let latitude, longitude: Double }
        let version, steps: Int
        let points: [Point]
        let firstInstruction: String
        var id: Int { version }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await check() }
            } label: {
                Label(loading ? "Checking route…" : "Preview with comma", systemImage: "car.fill")
            }
            .buttonStyle(.bordered)
            .disabled(loading || !connection.connected)
            Text(connection.connected ? "Check this route on your parked comma and see the result here before starting a trip." : "Connect to your parked comma to preview this route.")
                .font(.footnote).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.footnote) }
        }.sheet(item: $preview) { reply in
            NavigationStack {
                VStack {
                    Map {
                        MapPolyline(coordinates: reply.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                            .stroke(.purple, lineWidth: 5)
                    }
                    Text("Comma read \(reply.steps) route steps.").font(.headline)
                    if !reply.firstInstruction.isEmpty { Text(reply.firstInstruction) }
                    Text("Parked preview only").font(.footnote)
                }
                .navigationTitle("Route from comma")
                .toolbar { Button("Done") { preview = nil } }
            }
        }
    }

    @MainActor private func check() async {
        guard !loading else { return }
        loading = true
        message = ""
        defer { loading = false }
        let before = connection.session
        do {
            _ = try await connection.ensureDeviceIdentity()
            guard connection.session == before else { throw BridgeError.message("Connection changed.") }
            let status = try await connection.transport.request(path: "/api/navigation/status", method: "GET", headers: [:], body: Data())
            guard status.status == 200, connection.session == before else { throw BridgeError.message("Couldn’t verify your comma.") }
            let fields = try JSONSerialization.jsonObject(with: status.bodyData) as? [String: Any]
            guard fields?["phoneRoutePreviewVersion"] as? Int == 1 else {
                throw BridgeError.message("This comma firmware does not support iPhone route previews.")
            }
            let response = try await connection.transport.request(path: "/api/navigation/phone-preview", method: "POST",
                headers: ["content-type": "application/json"], body: bodyData)
            guard connection.session == before else { throw BridgeError.message("Connection changed. Try the preview again.") }
            guard response.status == 200 else { throw BridgeError.message(response.status == 409 ? "Park and reconnect to preview the route." : "Comma could not preview this route (HTTP \(response.status)).") }
            let reply = try JSONDecoder().decode(Reply.self, from: response.bodyData)
            guard reply.version == 1, (1...256).contains(reply.steps), (2...512).contains(reply.points.count),
                  reply.points.allSatisfy({ CLLocationCoordinate2DIsValid(.init(latitude: $0.latitude, longitude: $0.longitude)) }) else {
                throw BridgeError.message("Comma returned an incomplete preview.")
            }
            preview = reply
        } catch { message = error.localizedDescription }
    }
}


private struct CommaRouteOptionsState: Decodable {
    let revision: String
    let routeKey: String
    let destination: NavigationDestination?
    let selectedRoute: Int?
    let routeProvider: String?
    let alternatives: [Choice]?

    struct Choice: Decodable, Identifiable {
        let index: Int
        let distanceMeters: Double
        let durationSeconds: Double
        var id: Int { index }
    }
}

struct CommaRouteOptionsView: View {
    @ObservedObject var connection: CommaConnection
    @ObservedObject var navigation: NavigationModel
    let place: NavigationPlace
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NavigationDistanceUnits.key) private var units = NavigationDistanceUnits.system
    @State private var state: CommaRouteOptionsState?
    @State private var loadedSession: String?
    @State private var busy = false
    @State private var message = ""

    private func matchesPlace(_ state: CommaRouteOptionsState) -> Bool {
        guard let target = state.destination else { return false }
        return abs(place.coordinate.latitude - target.latitude) < 0.000001 &&
            abs(place.coordinate.longitude - target.longitude) < 0.000001
    }

    var body: some View {
        NavigationStack {
            List {
                if let state, loadedSession == connection.session {
                    if let provider = state.routeProvider, ["google", "mapbox"].contains(provider) {
                        LabeledContent("Preferred on comma", value: provider == "google" ? "Google Routes" : "Mapbox")
                    }
                    if navigation.navigating, navigation.usingComma, matchesPlace(state), let choices = state.alternatives, !choices.isEmpty {
                        Section(place.name) {
                            ForEach(choices) { choice in
                                Button { Task { await refresh(selecting: choice.index) } } label: {
                                    HStack {
                                        Text(NavigationDuration.text(choice.durationSeconds))
                                        Text(units.text(choice.distanceMeters)).foregroundStyle(.secondary)
                                        Spacer()
                                        if choice.index == state.selectedRoute { Image(systemName: "checkmark").accessibilityHidden(true) }
                                    }
                                }.disabled(choice.index == state.selectedRoute || busy || !connection.connected)
                                .accessibilityAddTraits(choice.index == state.selectedRoute ? .isSelected : [])
                            }
                        }
                    } else {
                        Text(navigation.navigating ? "Your comma has no route choices available right now." : "Send this destination to your comma to see the routes it finds.")
                    }
                }
                if !message.isEmpty { Text(message) }
                if busy { ProgressView() }
                else { Button("Refresh routes") { Task { await refresh() } } }
            }
            .navigationTitle("Route options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await refresh() }
    }

    @MainActor private func refresh(selecting index: Int? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let session = connection.session
        do {
            let identity = try await connection.ensureDeviceIdentity()
            func current() -> Bool {
                !Task.isCancelled && connection.connected && connection.session == session &&
                    connection.deviceIdentity == identity && navigation.destination?.id == place.id
            }
            guard current() else { throw CancellationError() }
            let reply = try await connection.transport.request(path: "/api/navigation/status", method: "GET", headers: [:], body: Data())
            guard current(), reply.status == 200 else { throw BridgeError.message("Reconnect to your comma and refresh routes.") }
            let latest = try JSONDecoder().decode(CommaRouteOptionsState.self, from: reply.bodyData)
            let previous = state
            state = latest
            message = ""
            if let index {
                guard loadedSession == session, navigation.navigating, navigation.usingComma, !navigation.busy,
                      matchesPlace(latest), previous?.revision == latest.revision, previous?.routeKey == latest.routeKey,
                      latest.alternatives?.contains(where: { $0.index == index }) == true else {
                    throw BridgeError.message("The route choices changed. Refresh to see the current trip.")
                }
                let payload: [String: Any] = ["action": "selectRoute", "revision": latest.revision, "index": index]
                let result = try await connection.transport.request(path: "/api/navigation/action", method: "POST",
                    headers: ["content-type": "application/json"], body: JSONSerialization.data(withJSONObject: payload))
                guard current(), result.status == 200 else { throw BridgeError.message("Route change unconfirmed. Refresh to check the selected route.") }
                let confirmed = try JSONDecoder().decode(CommaRouteOptionsState.self, from: result.bodyData)
                guard matchesPlace(confirmed), confirmed.selectedRoute == index else { throw BridgeError.message("Refresh to check the route on your comma.") }
                state = confirmed
            }
            loadedSession = session
        } catch {
            state = nil
            loadedSession = nil
            message = error.localizedDescription
        }
    }
}
