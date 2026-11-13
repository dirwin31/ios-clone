import Foundation

@MainActor final class RouteStub: GalaxyRequestTransport {
    var connected = true
    var fail = false
    var cancelRequest = false
    var delayNanoseconds: UInt64 = 0
    var status = 200
    var calls = 0
    let name: String
    init(_ name: String) { self.name = name }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        calls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if cancelRequest {
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
        if fail { throw URLError(.networkConnectionLost) }
        return BridgeResponse(id: "test", session: name, counter: 0, status: status, headers: [:], body: "")
    }
}
@MainActor final class TunnelServer {
    var identity = "0123456789abcdef"
    var status = 200
    var requests: [URLRequest] = []
    var errorBody: Data?
    var legacyOnly = false
    var redirect: String?
    var htmlEverywhere = false
    func load(_ request: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let errorBody, status >= 500 {
            return (errorBody, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "CF-Ray": "0123456789abcdef-YYZ", "Retry-After": "30", "Set-Cookie": "secret-cookie"])!)
        }
        if htmlEverywhere || (legacyOnly && request.url!.path.hasSuffix("/api/companion/runtime")) {
            return (Data(("<html>private response " + String(repeating: "x", count: 2580)).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/html"])!)
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "monitor": "local", "instance": identity])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: redirect.map { ["Location": $0] } ?? [:])!)
    }
}
@main struct TunnelRegression {
    @MainActor static func main() async throws {
        let url = "https://galaxy.firestar.link/abcdefghijklmnop"
        precondition(TunnelTransport.endpoint(url + "/")?.absoluteString == url)
        for bad in ["http://galaxy.firestar.link/abcdefghijklmnop", "https://evil.test/abcdefghijklmnop", url + "?cookie=x", url + "/api", "https://user@galaxy.firestar.link/abcdefghijklmnop", "https://galaxy.firestar.link:443/abcdefghijklmnop"] {
            precondition(TunnelTransport.endpoint(bad) == nil)
        }
        func sessionCookie(path: String, value: String, expired: Bool = false, secure: Bool = true, domain: String = "galaxy.firestar.link") -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "galaxy_session", .value: value, .domain: domain, .path: path,
                .expires: Date().addingTimeInterval(expired ? -3600 : 3600)]
            if secure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)!
        }
        let rootCookie = sessionCookie(path: "/", value: "root-token")
        let matchingCookie = sessionCookie(path: "/abcdefghijklmnop", value: "matching-token")
        let wrongCookie = sessionCookie(path: "/ponmlkjihgfedcba", value: "wrong-token")
        precondition(TunnelTransport.loginCookie([wrongCookie, rootCookie, matchingCookie], url: URL(string: url)!)?.value == "matching-token")
        precondition(TunnelTransport.loginCookie([wrongCookie], url: URL(string: url)!) == nil)
        precondition(TunnelTransport.loginCookie([sessionCookie(path: "/abcdefghijklmno", value: "prefix-token")], url: URL(string: url)!) == nil)
        precondition(TunnelTransport.loginCookie([sessionCookie(path: "/", value: "expired", expired: true), sessionCookie(path: "/", value: "insecure", secure: false), sessionCookie(path: "/", value: "foreign", domain: "evil.test")], url: URL(string: url)!) == nil)
        precondition(TunnelTransport.loginCookie([rootCookie], url: URL(string: url)!)?.value == "root-token")
        precondition(ConnectionRoute.normalized(["bluetooth", "bluetooth", "unknown"]) == [.bluetooth, .lan, .tunnel])
        let server = TunnelServer(), tunnel = TunnelTransport(load: { request, limit in try await server.load(request, limit) })
        try tunnel.configure(TunnelCredential(url: url, cookie: "opaque-token", deviceID: server.identity))
        tunnel.expectedDeviceID = server.identity
        let verified = await tunnel.probe(); precondition(verified)
        _ = try await tunnel.request(path: "/api/settings/confirm", method: "POST", headers: ["Authorization": "must-not-forward", "Cookie": "attacker"], body: Data("{}".utf8))
        let request = server.requests.last!
        precondition(request.url!.absoluteString == url + "/api/settings/confirm")
        precondition(request.value(forHTTPHeaderField: "Origin") == "https://galaxy.firestar.link")
        precondition(request.value(forHTTPHeaderField: "Cookie") == "galaxy_session=opaque-token")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        server.identity = "fedcba9876543210"
        let restarted = await tunnel.probe(); precondition(restarted, "Saved authenticated tunnel survives a Galaxy restart")
        tunnel.expectedDeviceID = "galaxy:another-comma"
        let wrong = await tunnel.probe(); precondition(!wrong && !tunnel.connected, "Never fall back to another comma’s tunnel")
        tunnel.expectedDeviceID = LANTransport.persistentIdentity(url: URL(string: url)!)
        server.identity = "0123456789abcdef"
        _ = await tunnel.probe()
        server.status = 302
        do { _ = try await tunnel.request(path: "/api/settings/pages/hub", method: "GET", headers: [:], body: Data()); preconditionFailure() } catch is URLError {}
        precondition(!tunnel.connected && !tunnel.loginRequired)
        server.redirect = "https://other.example/login"
        _ = await tunnel.probe()
        precondition(!tunnel.loginRequired)
        server.redirect = "/abcdefghijklmnop/login"
        _ = await tunnel.probe()
        precondition(tunnel.loginRequired)
        server.status = 200
        _ = await tunnel.probe()
        precondition(tunnel.connected && !tunnel.loginRequired)
        server.status = 401
        _ = await tunnel.probe()
        precondition(tunnel.loginRequired)
        for cookie in ["bad\r\nCookie:x", "bad;other=x", ""] {
            do { try tunnel.configure(TunnelCredential(url: url, cookie: cookie, deviceID: "")); preconditionFailure() } catch {}
        }
        let legacyServer = TunnelServer()
        legacyServer.legacyOnly = true
        let legacy = TunnelTransport(load: { try await legacyServer.load($0, $1) })
        try legacy.configure(TunnelCredential(url: url, cookie: "opaque-token", deviceID: ""))
        legacy.expectedDeviceID = LANTransport.persistentIdentity(url: URL(string: url)!)
        var details: [String] = []
        legacy.onDiagnostic = { details.append($0) }
        let legacyVerified = await legacy.probe()
        precondition(legacyVerified)
        precondition(legacyServer.requests.map { $0.url!.path } == ["/abcdefghijklmnop/api/companion/runtime", "/abcdefghijklmnop/data/runtime.json"])
        precondition(details.contains { $0.contains("HTML instead of runtime JSON") })
        precondition(!details.joined().contains("private response"))
        legacyServer.requests = []
        let cachedVerified = await legacy.probe()
        precondition(cachedVerified && legacyServer.requests.count == 1, "Cache working runtime path to avoid repeated failed probes")
        legacyServer.htmlEverywhere = true
        let invalid = await legacy.probe()
        precondition(!invalid && !legacy.connected && legacy.status.contains("HTML"), "Never accept a gateway HTML page as a verified comma")
        let deniedServer = TunnelServer(); deniedServer.status = 401
        let denied = TunnelTransport(load: { try await deniedServer.load($0, $1) })
        try denied.configure(TunnelCredential(url: url, cookie: "opaque-token", deviceID: ""))
        let deniedResult = await denied.probe()
        precondition(!deniedResult && deniedServer.requests.count == 1, "Do not retry an authentication rejection through another path")
        let unavailableServer = TunnelServer()
        unavailableServer.status = 503
        unavailableServer.errorBody = Data(#"{"error":"Comma cannot be reached: private-url secret-cookie", "code":"private-code"}"#.utf8)
        let unavailable = TunnelTransport(load: { try await unavailableServer.load($0, $1) })
        try unavailable.configure(TunnelCredential(url: url, cookie: "secret-cookie", deviceID: ""))
        var failureEvents: [String] = []
        unavailable.onDiagnostic = { failureEvents.append($0) }
        let unavailableResult = await unavailable.probe()
        precondition(!unavailableResult && !unavailable.connected)
        precondition(unavailableServer.requests.map { $0.url!.path } == ["/abcdefghijklmnop/api/companion/runtime", "/abcdefghijklmnop/data/runtime.json", "/abcdefghijklmnop/api/auth/session"])
        precondition(unavailableServer.requests.allSatisfy { $0.httpMethod == "GET" })
        let failureText = failureEvents.joined()
        precondition(failureText.contains("category=upstream-unreachable") && failureText.contains("cf-ray=0123456789abcdef-YYZ") && failureText.contains("retry-after seconds=30"))
        for secret in ["private-url", "secret-cookie", "private-code", "abcdefghijklmnop"] { precondition(!failureText.contains(secret)) }
        let repeatedFailure = await unavailable.probe()
        precondition(!repeatedFailure && unavailableServer.requests.count == 4, "Failure comparisons are rate limited")
        let diagnosticSuccess = TunnelTransport(load: { request, _ in
            let primary = request.url!.path.hasSuffix("/api/companion/runtime")
            let body = primary ? Data(#"{"error":"offline"}"#.utf8) : Data(#"{"schemaVersion":1,"monitor":"local","instance":"0123456789abcdef","authenticated":true,"gatewayAccess":true}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: primary ? 503 : 200, httpVersion: nil, headerFields: nil)!)
        })
        try diagnosticSuccess.configure(TunnelCredential(url: url, cookie: "opaque-token", deviceID: ""))
        var comparisonEvents: [String] = []
        diagnosticSuccess.onDiagnostic = { comparisonEvents.append($0) }
        let comparisonVerified = await diagnosticSuccess.probe()
        precondition(!comparisonVerified && !diagnosticSuccess.connected, "Diagnostic success must not override the failing primary probe")
        precondition(comparisonEvents.contains { $0.contains("authenticated=true; gatewayAccess=true") })
        let unsafeHeaders = HTTPURLResponse(url: URL(string: url)!, statusCode: 503, httpVersion: nil, headerFields: ["CF-Ray": "secret-cookie", "Location": url, "Retry-After": "secret-cookie"])!
        let unknownFailure = TunnelTransport.failureDiagnostic(Data(#"{"error":"secret-cookie"}"#.utf8), unsafeHeaders)
        precondition(unknownFailure.contains("category=unclassified") && unknownFailure.contains("redirect present=true"))
        precondition(!unknownFailure.contains("secret-cookie") && !unknownFailure.contains(url))
        let wifi = RouteStub("wifi"), remote = RouteStub("tunnel"), ble = RouteStub("ble")
        let preferred = PreferredTransport(lan: wifi, bluetooth: ble, tunnel: remote,
            invalidateTunnel: { _ in remote.connected = false }, invalidateLAN: { _ in wifi.connected = false })
        var routeEvents: [String] = []
        var loggedLocalDelays: [TimeInterval?] = []
        preferred.onDiagnostic = { routeEvents.append($0); loggedLocalDelays.append(preferred.localRefreshDelay) }
        precondition(preferred.label == "Local Wi-Fi")
        precondition(preferred.localRefreshDelay == 0.2)
        wifi.status = 503
        _ = try await preferred.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(preferred.localRefreshDelay == 2)
        precondition(loggedLocalDelays.last! == 2, "Update transport timing before invoking diagnostics")
        wifi.status = 200
        _ = try await preferred.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(preferred.localRefreshDelay == 1.8)
        precondition(loggedLocalDelays.last! == 1.8, "Recovery should be logged after updating cadence")
        preferred.priority = [.tunnel, .bluetooth, .lan]
        precondition(preferred.label == "Tunnel")
        precondition(preferred.localRefreshDelay == nil)
        remote.fail = true
        let fallback = try await preferred.request(path: "/api/settings/pages/hub", method: "GET", headers: [:], body: Data())
        precondition(fallback.session == "ble" && ble.connected && wifi.connected)
        remote.connected = true
        let before = ble.calls
        do { _ = try await preferred.request(path: "/api/settings/confirm", method: "POST", headers: [:], body: Data("{}".utf8)); preconditionFailure() } catch {}
        precondition(ble.calls == before, "Never replay uncertain writes")
        precondition(routeEvents.contains { $0.contains("completed over lan: HTTP 503") })
        precondition(routeEvents.contains { $0.contains("read fallback") })
        precondition(routeEvents.contains { $0.contains("replay blocked") })
        precondition(routeEvents.contains { $0.contains("completed over bluetooth") })
        precondition(!routeEvents.contains { $0.contains("dispatched over") }, "Routine requests need only one completion event")
        let rejected = SecretGoodGalaxy.responseDiagnostic(Data(#"{"error":"Missing app request key."}"#.utf8), status: 403)
        precondition(rejected.contains("missing-app-request-key"))
        let privateBody = Data(#"{"error":"secret-token private coordinates","code":"private-code"}"#.utf8)
        let safe = SecretGoodGalaxy.responseDiagnostic(privateBody, status: 403)
        precondition(safe.contains("unrecognized-json") && !safe.contains("secret-token") && !safe.contains("private-code"))
        precondition(SecretGoodGalaxy.responseDiagnostic(Data("<html>secret</html>".utf8), status: 403).contains("rejection=html"))
        precondition(SecretGoodGalaxy.responseDiagnostic(Data(repeating: 65, count: 16_385), status: 403).contains("oversized-body"))
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: Data(#"{"error":"Missing app request key."}"#.utf8).base64EncodedString()).contains("missing-app-request-key"))
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 401, encodedBody: Data(#"{"error":"Refresh the local Galaxy session"}"#.utf8).base64EncodedString()).contains("refresh-local-session"))
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: privateBody.base64EncodedString()) == safe)
        let largeSuccess = String(repeating: "!", count: 1_000_000)
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 200, encodedBody: largeSuccess) == "body base64 bytes=1000000", "Successful diagnostics use encoded size without requiring a decoded body")
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: largeSuccess).contains("oversized-body"), "Reject oversized input before attempting base64 decoding")
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: "!!!!").contains("invalid-base64"))
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: "abc").contains("invalid-base64"))
        precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: Data(repeating: 65, count: 16_384).base64EncodedString()).contains("bytes=16384; rejection=non-json"))
        for count in [16_385, 16_386, 16_387] {
            precondition(SecretGoodGalaxy.responseDiagnostic(status: 403, encodedBody: Data(repeating: 65, count: count).base64EncodedString()).contains("oversized-body"), "Base64 padding must not permit oversized decoded bodies")
        }

        // Sampling is clock-driven without timers, and a forced event carries all sampled successes.
        var sampler = DiagnosticSuccessSampler()
        precondition(sampler.take(routineSuccess: true, now: 100) == 0)
        precondition(sampler.take(routineSuccess: true, now: 101) == nil)
        precondition(sampler.take(routineSuccess: true, now: 109.999) == nil)
        precondition(sampler.take(routineSuccess: true, now: 110) == 2)
        precondition(sampler.take(routineSuccess: true, now: 111) == nil)
        precondition(sampler.take(routineSuccess: false, now: 112) == 1)
        precondition(sampler.take(routineSuccess: false, now: 112) == 0, "Consecutive failures/notable events must never be sampled")

        let sampledLAN = RouteStub("sampled-lan"), sampledBLE = RouteStub("sampled-ble")
        let sampled = PreferredTransport(lan: sampledLAN, bluetooth: sampledBLE, invalidateLAN: { _ in sampledLAN.connected = false })
        var sampledEvents: [String] = []
        sampled.onDiagnostic = { sampledEvents.append($0) }
        for _ in 0..<4 { _ = try await sampled.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data()) }
        precondition(sampledLAN.calls == 4 && sampledEvents.count == 1, "Sample diagnostic output without sampling actual requests")
        _ = try await sampled.request(path: "/api/companion/location", method: "POST", headers: [:], body: Data("{}".utf8))
        precondition(sampledLAN.calls == 5 && sampledEvents.count == 1, "Routine GPS success joins the summary")
        _ = try await sampled.request(path: "/api/settings/confirm", method: "POST", headers: [:], body: Data("{}".utf8))
        precondition(sampledEvents.count == 2 && sampledEvents.last!.contains("routine successes sampled=4"), "Mutations always emit and identify sampled successes")
        sampledLAN.status = 403
        for _ in 0..<2 { _ = try await sampled.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data()) }
        precondition(sampledEvents.count == 4 && sampledEvents.suffix(2).allSatisfy { $0.contains("HTTP 403") }, "Keep every rejection")
        sampledLAN.status = 200
        _ = try await sampled.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(sampledEvents.count == 5 && sampledEvents.last!.contains("HTTP 200"), "Keep the first success after failures")
        sampled.priority = [.bluetooth, .lan, .tunnel]
        _ = try await sampled.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(sampledEvents.count == 6 && sampledEvents.last!.contains("completed over bluetooth"), "Keep a route transition")
        sampledBLE.delayNanoseconds = 2_010_000_000
        _ = try await sampled.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(sampledEvents.count == 7, "Slow successful reads must not be sampled")

        // Cancellation after dispatch must still stop fallback and leave the route's connection intact.
        let cancellingLAN = RouteStub("cancelled-lan"), untouchedBLE = RouteStub("untouched-ble")
        cancellingLAN.cancelRequest = true
        let cancelling = PreferredTransport(lan: cancellingLAN, bluetooth: untouchedBLE, invalidateLAN: { _ in cancellingLAN.connected = false })
        var cancellationEvents: [String] = []
        cancelling.onDiagnostic = { cancellationEvents.append($0) }
        let cancelledRequest = Task { try await cancelling.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data()) }
        do { _ = try await cancelledRequest.value; preconditionFailure("A cancelled request returned success") } catch is CancellationError {}
        precondition(cancellingLAN.calls == 1 && untouchedBLE.calls == 0 && cancellingLAN.connected)
        precondition(cancellationEvents.count == 1 && cancellationEvents[0].contains("cancelled=true"))
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelling.request(path: "/api/settings/confirm", method: "POST", headers: [:], body: Data("{}".utf8))
        }
        do { _ = try await alreadyCancelled.value; preconditionFailure("An already-cancelled write reached a route") } catch is CancellationError {}
        precondition(cancellingLAN.calls == 1 && untouchedBLE.calls == 0)
        precondition(cancellationEvents.count == 2 && cancellationEvents.last!.contains("cancelled before dispatch"))
        preferred.mode = .lan
        precondition(preferred.label == "Local Wi-Fi")
        preferred.mode = .bluetooth
        precondition(preferred.label == "Bluetooth")
        precondition(preferred.localRefreshDelay == nil)
        print("Tunnel identity/auth, origin and cookie isolation, priority, fallback and no-write-replay checks passed")
    }
}
