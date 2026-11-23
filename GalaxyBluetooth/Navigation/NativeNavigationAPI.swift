import Foundation

struct PhoneTripRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Adapter for the navigation API already installed on the newer StarPilot fork.
/// It never changes configuration or GPS-source settings and never retries a write.
enum NativeNavigationAPI {
    @MainActor
    static func sendPhoneTrip(destination: NavigationDestination, route: Data, revision: String, supportsOnroad: Bool,
                              transport: any GalaxyRequestTransport, willSend: () -> Void = {}, stillCurrent: () -> Bool) async throws -> String {
        let body: [String: Any] = ["revision": revision, "phoneRoute": try JSONSerialization.jsonObject(with: route),
            "destination": ["name": destination.name, "latitude": destination.latitude, "longitude": destination.longitude]]
        guard stillCurrent(), !Task.isCancelled else { throw CancellationError() }
        willSend()
        let reply = try await transport.request(path: "/api/navigation/phone-trip", method: "POST",
            headers: ["content-type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        guard stillCurrent() else { throw BridgeError.message("Connection changed. Check the active trip on comma.") }
        guard reply.status == 200 else {
            let detail = try? JSONSerialization.jsonObject(with: reply.bodyData) as? [String: Any]
            let reason = detail?["error"] as? String ?? ""
            if reply.status == 409 {
                if detail?["code"] as? String == "trip_changed" || reason.hasPrefix("Navigation changed") {
                    throw PhoneTripRejection(message: "The active trip changed. Review the route and send it again.")
                }
                if reason.hasPrefix("Park and reconnect"), !supportsOnroad {
                    throw PhoneTripRejection(message: "This comma software accepts iPhone routes while parked. For on-road handoff, update the comma to a version that supports it.")
                }
                throw PhoneTripRejection(message: "The comma declined this trip. Refresh the route and try again.")
            }
            if reply.status == 400 {
                throw PhoneTripRejection(message: "The comma could not use this route. Check its navigation setup and choose a fresh route from your current location.")
            }
            throw BridgeError.message("Comma returned HTTP \(reply.status) for the iPhone route.")
        }
        struct Receipt: Decodable { let revision: String; let activeRouteSource: String; let destination: NavigationDestination }
        let receipt = try JSONDecoder().decode(Receipt.self, from: reply.bodyData)
        guard receipt.activeRouteSource == "iphone", !receipt.revision.isEmpty, receipt.destination.matches(destination) else { throw NavigationContractError.invalidResponse }
        return receipt.revision
    }

    // Native status provides a 3-second upper bound, not a sample timestamp.
    // Allow a bounded Bluetooth delivery/poll interval for guidance only. GPS keeps
    // its independent <=2.5-second expiry and is never extended by this policy.
    static let guidanceDisplayMaxAge: TimeInterval = 12
    static func guidanceRemaining(ageUpperBound: Double?, elapsed: Double) -> Double {
        guard let ageUpperBound, ageUpperBound.isFinite, ageUpperBound >= 0,
              elapsed.isFinite, elapsed >= 0 else { return 0 }
        return max(0, guidanceDisplayMaxAge - ageUpperBound - elapsed)
    }
    struct State: Decodable {
        let activeRouteSource: String?
        let phoneRouteTripOnroad: Bool?
        let revision: String
        let enabled: Bool
        let hasKey: Bool
        let status: String
        let destination: NavigationDestination?
        let routeKey: String
        let route: [Point]?
        let routeUnchanged: Bool?
        let location: Location?
        let instruction: Instruction?
        struct Point: Decodable { let latitude: Double; let longitude: Double }
        struct Location: Decodable {
            let latitude: Double; let longitude: Double
            let bearing: Double?
            let validForMs: Double?
            let lastKnown: Bool?
        }
        struct Instruction: Decodable {
            let text: String; let maneuverType: String; let maneuverModifier: String
            let distanceMeters: Double; let remainingDistanceMeters: Double; let remainingDurationSeconds: Double
        }
        func validate() throws {
            guard !revision.isEmpty, revision.count <= 128,
                  ["disabled", "needsKey", "noDestination", "waitingForLocation", "routing", "guiding", "arrived", "routeUnavailable", "stale"].contains(status),
                  routeKey.count == 16, routeKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (route != nil || routeUnchanged == true),
                  (route ?? []).count <= 512, (route ?? []).allSatisfy({ Self.coordinate($0.latitude, $0.longitude) }) else { throw NavigationContractError.invalidResponse }
            if let location {
                guard Self.coordinate(location.latitude, location.longitude),
                      location.bearing == nil || (location.bearing!.isFinite && (0..<360).contains(location.bearing!)),
                      location.validForMs == nil || (location.validForMs!.isFinite && (0...2500).contains(location.validForMs!)) else { throw NavigationContractError.invalidResponse }
            }
            if let i = instruction {
                guard i.text.count <= 512, i.maneuverType.count <= 128, i.maneuverModifier.count <= 128,
                      [i.distanceMeters, i.remainingDistanceMeters, i.remainingDurationSeconds].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw NavigationContractError.invalidResponse }
            }
        }
        private static func coordinate(_ latitude: Double, _ longitude: Double) -> Bool {
            latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }
    static func decode(_ data: Data) throws -> State {
        let state = try JSONDecoder().decode(State.self, from: data)
        try state.validate()
        return state
    }
    static func identity(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1, object["monitor"] as? String == "local",
              let value = object["instance"] as? String, value.count == 16,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    // Destination commands can run before a GPS fix or a drawable route exists.
    private struct CommandState: Decodable {
        let revision: String
        let enabled: Bool
        let hasKey: Bool
        let destination: NavigationDestination?

        enum CodingKeys: String, CodingKey { case revision, enabled, hasKey, destination }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            revision = try fields.decode(String.self, forKey: .revision)
            enabled = try fields.decode(Bool.self, forKey: .enabled)
            hasKey = try fields.decode(Bool.self, forKey: .hasKey)
            // Require the field; explicit null confirms a cleared destination.
            destination = try fields.decode(NavigationDestination?.self, forKey: .destination)
            guard !revision.isEmpty, revision.count <= 128 else { throw NavigationContractError.invalidResponse }
        }
    }

    @MainActor
    static func command(_ command: NavigationCommand, transport: any GalaxyRequestTransport,
                        expectedRevision: String? = nil, routeVersion: String? = nil, willSend: () -> Void = {}, stillCurrent: () -> Bool) async throws -> Data {
        let response = try await transport.request(path: try statusPath(version: routeVersion), method: "GET", headers: [:], body: Data())
        guard stillCurrent(), response.status == 200 else { throw BridgeError.message("Couldn’t verify comma’s navigation state.") }
        let state = try JSONDecoder().decode(CommandState.self, from: response.bodyData)
        if case .read = command {
            let destination = try state.destination.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
            return try JSONSerialization.data(withJSONObject: ["destination": destination, "nativeRevision": state.revision])
        }
        var payload: [String: Any] = ["revision": state.revision]
        switch command {
        case .start(let destination):
            guard state.enabled, state.hasKey else { throw BridgeError.message("Enable navigation and configure its map key in Galaxy on comma first.") }
            payload["action"] = "select"
            payload["destination"] = ["name": destination.name, "latitude": destination.latitude, "longitude": destination.longitude]
        case .end:
            guard expectedRevision == state.revision else { throw BridgeError.message("Comma’s route changed. Check its screen before ending it.") }
            payload["action"] = "clear"
        case .read: break
        }
        guard stillCurrent() else { throw BridgeError.message("Comma connection changed.") }
        willSend()
        let result = try await transport.request(path: "/api/navigation/action", method: "POST", headers: ["content-type": "application/json"],
                                                 body: JSONSerialization.data(withJSONObject: payload))
        guard stillCurrent(), result.status == 200 else {
            throw BridgeError.message("Comma did not confirm navigation (HTTP \(result.status)). Check its screen before retrying.")
        }
        let confirmed = try JSONDecoder().decode(CommandState.self, from: result.bodyData)
        switch command {
        case .start(let destination): guard confirmed.destination?.matches(destination) == true else { throw NavigationContractError.invalidResponse }
        case .end: guard confirmed.destination == nil else { throw NavigationContractError.invalidResponse }
        case .read: break
        }
        return result.bodyData
    }
    static func statusPath(version: String?) throws -> String {
        guard let version else { return "/api/navigation/status" }
        guard version.count == 64, version.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              String(repeating: String(version.prefix(16)), count: 4) == version else { throw NavigationContractError.invalidResponse }
        return "/api/navigation/status?routeKey=" + version.prefix(16)
    }
    static func snapshot(_ data: Data) throws -> CommaRouteSnapshot {
        let state = try decode(data)
        let guiding = ["guiding", "arrived"].contains(state.status) && state.instruction != nil && state.destination != nil && ((state.route?.count ?? 0) >= 2 || state.routeUnchanged == true)
        let location = state.location
        let live = location?.lastKnown != true && (location?.validForMs ?? 0) > 0
        let position = live ? location.map { CommaPosition(latitude: $0.latitude, longitude: $0.longitude, bearing: $0.bearing) } : nil
        let instruction = guiding ? state.instruction.map { CommaInstruction(primary: $0.text, secondary: "", distance: $0.distanceMeters,
            distanceRemaining: $0.remainingDistanceMeters, timeRemaining: $0.remainingDurationSeconds, type: $0.maneuverType, modifier: $0.maneuverModifier) } : nil
        // The server bounds guidance age to 3 seconds but doesn't expose its timestamp.
        // Use that upper bound, rather than pretending every response is a new sample.
        var result = CommaRouteSnapshot(protocolVersion: 1, ready: state.enabled && state.hasKey, source: "comma",
            status: guiding ? "active" : state.destination == nil ? "inactive" : "waiting", ageSeconds: guiding ? 3 : nil,
            destination: state.destination, position: position, routeVersion: String(repeating: state.routeKey, count: 4), polyline6: nil,
            instruction: instruction, error: ["disabled": "Enable navigation in Galaxy on comma.", "needsKey": "Configure the map key in Galaxy on comma.",
                "waitingForLocation": "Destination received. Waiting for GPS on comma.",
                "routing": "Destination received. Comma is calculating the route.",
                "routeUnavailable": "Comma couldn’t calculate a route.", "stale": "Waiting for fresh navigation from comma…"][state.status])
        result.phoneTripOnroad = state.phoneRouteTripOnroad == true
        result.routeUnavailable = state.status == "routeUnavailable"
        result.phoneTripRevision = state.activeRouteSource == "iphone" ? state.revision : nil
        result.routePoints = state.route.map { $0.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) } }
        result.positionValidForSeconds = live ? (location?.validForMs ?? 0) / 1000 : 0
        try result.validate()
        return result
    }
}
