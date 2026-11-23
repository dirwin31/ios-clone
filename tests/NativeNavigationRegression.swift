import Foundation

@MainActor final class NativeComma: GalaxyRequestTransport {
    var connected = true
    var response: [String: Any] = ["revision":"a", "enabled":true, "hasKey":true, "status":"noDestination", "destination":NSNull(), "routeKey":"0123456789abcdef", "route":[], "location":NSNull(), "instruction":NSNull()]
    var reads: [String] = []
    var writes: [[String: Any]] = []
    var writeStatus = 200
    var changeConnection = false
    var afterRead: (() -> Void)?
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        if method == "GET" {
            precondition(path.hasPrefix("/api/navigation/status") && body.isEmpty)
            reads.append(path)
            let data = try JSONSerialization.data(withJSONObject: response)
            afterRead?()
            return make(200, data)
        }
        if path == "/api/navigation/phone-trip" {
            precondition(method == "POST")
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            writes.append(payload)
            guard payload["revision"] as? String == response["revision"] as? String else { return make(409, Data()) }
            response["activeRouteSource"] = "iphone"
            response["revision"] = "replacement"
            response["destination"] = payload["destination"]
            return make(200, try JSONSerialization.data(withJSONObject: response))
        }
        precondition(method == "POST" && path == "/api/navigation/action")
        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        writes.append(payload)
        precondition(Set(payload.keys) == (payload["action"] as? String == "select" ? Set(["action", "revision", "destination"]) : Set(["action", "revision"])))
        if writeStatus == 200 {
            response["destination"] = payload["destination"] ?? NSNull()
            response["revision"] = "b"
        }
        return make(writeStatus, try JSONSerialization.data(withJSONObject: response))
    }
    func make(_ status: Int, _ data: Data) -> BridgeResponse {
        BridgeResponse(id: "test", session: "test", counter: 1, status: status, headers: [:], body: data.base64EncodedString())
    }
}
@main struct NativeNavigationRegression {
    static func tryPath(_ version: String?) -> String { try! NativeNavigationAPI.statusPath(version: version) }
    @MainActor static func main() async throws {
        if #available(macOS 13.0, *) {
            precondition(NavigationDistanceUnits.metric.measurement(999).unit == .meters)
            precondition(NavigationDistanceUnits.metric.measurement(1000).value == 1)
            let mile = NavigationDistanceUnits.imperial.measurement(1609.344)
            precondition(mile.unit == .miles && abs(mile.value - 1) < 0.00001)
        }
        let status = NativeComma().response
        let legacyFeed = try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: status))
        precondition(legacyFeed.phoneTripRevision == nil)
        var handoff = status
        handoff["activeRouteSource"] = "iphone"
        let phoneFeed = try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: handoff))
        precondition(phoneFeed.phoneTripRevision == "a")
        handoff["status"] = "routeUnavailable"
        handoff["phoneRouteTripOnroad"] = true
        handoff["destination"] = ["name": "Trip", "latitude": 43, "longitude": -80] as [String: Any]
        let missed = try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: handoff))
        precondition(missed.needsPhoneReroute(for: "a", offRouteSamples: 0))
        precondition(!missed.needsPhoneReroute(for: "new trip", offRouteSamples: 10))
        precondition(!legacyFeed.needsPhoneReroute(for: "a", offRouteSamples: 10))
        handoff["phoneRouteTripOnroad"] = false
        let parkedOnly = try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: handoff))
        precondition(!parkedOnly.needsPhoneReroute(for: "a", offRouteSamples: 10))
        let peer = NativeComma()
        let target = try NavigationDestination(name: "Test", latitude: 43, longitude: -80)
        let body = Data("{}".utf8)
        let replacement = try await NativeNavigationAPI.sendPhoneTrip(destination: target, route: body, revision: "a",
            supportsOnroad: true, transport: peer, stillCurrent: { true })
        precondition(replacement == "replacement" && peer.writes.count == 1)
        do {
            _ = try await NativeNavigationAPI.sendPhoneTrip(destination: target, route: body, revision: "a",
                supportsOnroad: true, transport: peer, stillCurrent: { true })
            preconditionFailure("Replaced a different trip")
        } catch is PhoneTripRejection { }
        precondition(peer.writes.count == 2 && peer.reads.isEmpty, "A conflict must never refresh and replay the write")
        do {
            _ = try await NativeNavigationAPI.sendPhoneTrip(destination: target, route: body, revision: replacement,
                supportsOnroad: true, transport: peer, stillCurrent: { false })
            preconditionFailure("A cancelled trip was sent")
        } catch is CancellationError { }
        precondition(peer.writes.count == 2)
        precondition(NavigationMapMotion.carPlayAnimationDuration(interval: 1, fixAge: 0) == 1)
        precondition(NavigationMapMotion.carPlayAnimationDuration(interval: 1, fixAge: 0.75) == 0.25)
        precondition(NavigationMapMotion.carPlayAnimationDuration(interval: 1, fixAge: 2) == 0.1)
        let landscapePitch = NavigationMapMotion.carPlayCruisingPitch(68, mapHeight: 300, phoneHeight: 800)
        precondition((68...76).contains(landscapePitch) && landscapePitch > 68)
        let ray = atan(1.0 / 3.0)
        let phoneReach = 800 / cos(68 * .pi / 180 + ray)
        let carReach = 300 / cos(landscapePitch * .pi / 180 + ray)
        precondition(abs(carReach / phoneReach - 1) < 0.0001)
        precondition(NavigationMapMotion.carPlayCruisingPitch(68, mapHeight: 880, phoneHeight: 800) == 68)
        precondition(NavigationMapMotion.carPlayCruisingPitch(0, mapHeight: 300, phoneHeight: 800) == 0)
        precondition(NavigationMapMotion.carPlayCruisingPitch(80, mapHeight: 300, phoneHeight: 800) == 80)
        let straight = [RoutePoint(latitude: 43, longitude: -80), RoutePoint(latitude: 43.01, longitude: -80)]
        let beside = RoutePoint(latitude: 43.005, longitude: -79.9999)
        let aligned = NavigationMapMotion.routeAligned(beside, route: straight)
        precondition(NavigationMapMotion.followPitch(cruising: 68, speed: 12, turnDistance: nil) == 68)
        precondition(NavigationMapMotion.followPitch(cruising: 68, speed: 12, turnDistance: 400) == 68)
        precondition(NavigationMapMotion.followPitch(cruising: 68, speed: 12, turnDistance: 20) == 32)
        precondition(NavigationMapMotion.followPitch(cruising: 68, speed: 0, turnDistance: 165) < 45)
        precondition((32..<68).contains(NavigationMapMotion.followPitch(cruising: 68, speed: 12, turnDistance: 80)))
        precondition(abs(aligned.longitude + 80) < 0.0000001 && abs(aligned.latitude - beside.latitude) < 0.0000001)
        let offRoute = RoutePoint(latitude: 43.005, longitude: -79.999)
        precondition(NavigationMapMotion.routeAligned(offRoute, route: straight) == offRoute)
        let parallel = straight + [RoutePoint(latitude: 43.01, longitude: -79.9998), RoutePoint(latitude: 43, longitude: -79.9998)]
        precondition(NavigationMapMotion.routeAligned(beside, route: parallel) == beside)
        let street = NavigationMapMotion.cameraDistance(speed: 10, distanceToTurn: 2000)
        let highway = NavigationMapMotion.cameraDistance(speed: 30, distanceToTurn: 2000)
        precondition(highway > street)
        let near = NavigationMapMotion.cameraDistance(speed: 20, distanceToTurn: 50)
        precondition(near < street)
        precondition(abs(NavigationMapMotion.cameraDistance(speed: 20, distanceToTurn: 299) -
            NavigationMapMotion.cameraDistance(speed: 20, distanceToTurn: 301)) < 15,
            "Crossing 300m must not cause a zoom jump")
        var zoom = 3000.0
        for _ in 0..<180 {
            let next = NavigationMapMotion.smoothDistance(zoom, toward: 1200, elapsed: 1.0 / 30)
            precondition(next <= zoom && next >= 1200 && zoom - next < 50)
            zoom = next
        }
        precondition(zoom < 1250)
        // Reproduce build 45: a 3s server upper bound plus 5.449s BLE transfer
        // must leave time for another compact poll, without making old GPS live.
        precondition(NativeNavigationAPI.guidanceRemaining(ageUpperBound: 3, elapsed: 5.449) > 3)
        precondition(NativeNavigationAPI.guidanceRemaining(ageUpperBound: 3, elapsed: 0.795) > 8)
        precondition(NativeNavigationAPI.guidanceRemaining(ageUpperBound: 3, elapsed: 9) == 0)
        precondition(NativeNavigationAPI.guidanceRemaining(ageUpperBound: nil, elapsed: 0) == 0)
        precondition(NativeNavigationAPI.guidanceRemaining(ageUpperBound: 3, elapsed: .infinity) == 0)
        let comma = NativeComma()
        let destination = try NavigationDestination(name: "Test", latitude: 40, longitude: -110)
        let beforeGPS = NativeComma()
        beforeGPS.response.removeValue(forKey: "routeKey")
        beforeGPS.response.removeValue(forKey: "route")
        _ = try await NativeNavigationAPI.command(.start(destination), transport: beforeGPS, stillCurrent: { true })
        precondition(beforeGPS.writes.count == 1, "Sending a destination cannot require guidance geometry")
        let read = try await NativeNavigationAPI.command(.read, transport: comma, stillCurrent: { true })
        let readDestination = try NavigationCommand.activeDestination(in: read)
        precondition(readDestination == nil)
        _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { true })
        precondition(comma.writes.count == 1 && comma.writes[0]["revision"] as? String == "a")
        do { _ = try await NativeNavigationAPI.command(.end, transport: comma, expectedRevision: "a", stillCurrent: { true }); preconditionFailure("Ended a replacement route") } catch {}
        precondition(comma.writes.count == 1)
        _ = try await NativeNavigationAPI.command(.end, transport: comma, expectedRevision: "b", stillCurrent: { true })
        precondition(comma.writes.count == 2)
        // Command preflights may omit unchanged geometry, but keep revision checks.
        comma.response.removeValue(forKey: "route")
        comma.response["routeUnchanged"] = true
        let version = String(repeating: "0123456789abcdef", count: 4)
        _ = try await NativeNavigationAPI.command(.read, transport: comma, routeVersion: version, stillCurrent: { true })
        precondition(comma.reads.last == "/api/navigation/status?routeKey=0123456789abcdef")
        do {
            _ = try await NativeNavigationAPI.command(.end, transport: comma, expectedRevision: "old", routeVersion: version, stillCurrent: { true })
            preconditionFailure("Compact status bypassed revision protection")
        } catch {}
        precondition(comma.writes.count == 2)

        comma.writeStatus = 409
        do { _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { true }); preconditionFailure() } catch {}
        precondition(comma.writes.count == 3, "A conflicting mutation was retried")
        comma.afterRead = { comma.changeConnection = true }
        do { _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { !comma.changeConnection }); preconditionFailure() } catch {}
        precondition(comma.writes.count == 3)
        comma.afterRead = nil
        var state = comma.response
        state["destination"] = ["name":"Test", "latitude":40, "longitude":-110]
        state["status"] = "guiding"
        state["route"] = [["latitude":40, "longitude":-110], ["latitude":40.01, "longitude":-110.01]]
        state["location"] = ["latitude":40, "longitude":-110, "bearing":90, "validForMs":1000]
        state["instruction"] = ["text":"Turn left", "maneuverType":"turn", "maneuverModifier":"left", "distanceMeters":100, "remainingDistanceMeters":1000, "remainingDurationSeconds":200]
        func snapshot() throws -> CommaRouteSnapshot { try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: state)) }
        let active = try snapshot()
        precondition(active.status == "active" && active.ageSeconds == 3 && active.routePoints?.count == 2 && active.position != nil)
        precondition(tryPath(active.routeVersion) == "/api/navigation/status?routeKey=0123456789abcdef")
        state["location"] = ["latitude":40, "longitude":-110, "validForMs":2500] as [String:Any]
        let noHeading = try snapshot()
        precondition(noHeading.position != nil && noHeading.position?.bearing == nil, "Unknown heading became north")
        let completeRoute = state.removeValue(forKey: "route")!
        state["routeUnchanged"] = true
        let unchanged = try snapshot()
        precondition(unchanged.status == "active" && unchanged.routePoints == nil)
        state["route"] = completeRoute
        state.removeValue(forKey: "routeUnchanged")
        state["location"] = ["latitude":40, "longitude":-110, "bearing":90, "validForMs":0, "lastKnown":true] as [String:Any]
        let saved = try snapshot()
        precondition(saved.position == nil, "Saved coordinates shown as live")
        state["status"] = "stale"
        let stale = try snapshot()
        precondition(stale.status == "waiting")
        state["route"] = [["latitude":1000, "longitude":0]]
        do { _ = try snapshot(); preconditionFailure("Invalid geometry accepted") } catch {}
        print("Native navigation: revision barriers, no write replay, session changes, schema, freshness, geometry passed")
    }
}
