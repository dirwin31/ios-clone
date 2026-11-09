import Foundation
import CryptoKit

@main struct ShareRelayRegression {
    static func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func reply(_ request: URLRequest, _ code: Int, _ body: Data, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    static func main() async {
        precondition(ShareClient.lanEndpoint("192.168.10.85")?.absoluteString == "http://192.168.10.85:8082")
        precondition(ShareClient.lanEndpoint("http://10.0.0.2:8082/")?.absoluteString == "http://10.0.0.2:8082")
        precondition(ShareClient.lanEndpoint("8.8.8.8") == nil && ShareClient.lanEndpoint("192.168.1.010") == nil && ShareClient.lanEndpoint("127.0.0.1") == nil)
        precondition(ShareClient.tunnelEndpoint("https://galaxy.firestar.link/AbCdEfGh12345678/")?.absoluteString == "https://galaxy.firestar.link/AbCdEfGh12345678")
        precondition(ShareClient.tunnelEndpoint("https://evil.example/AbCdEfGh12345678") == nil)

        let link = "https://galaxy.firestar.link/AbCdEfGh12345678"
        let identity = "galaxy:" + SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined()
        var log: [(URLRequest, Bool)] = []
        var sessions = 0
        var refreshOnce = true
        let shared = json(["shared": ["name": "Bellagio", "latitude": 36.1, "longitude": -115.1]])
        func lanComma(paired url: String) -> ShareClient.Load {
            return { request, local in
                log.append((request, local))
                switch request.url!.path {
                case "/api/auth/session":
                    sessions += 1
                    return reply(request, 200, json(["authenticated": true, "localAccess": true]), ["Set-Cookie": "galaxy_session=s\(sessions); Path=/; HttpOnly"])
                case "/api/galaxy/status": return reply(request, 200, json(["paired": true, "url": url]))
                case "/api/navigation/status": return reply(request, 200, json(["revision": "r1"]))
                case "/api/navigation/action":
                    if refreshOnce { refreshOnce = false; return reply(request, 401, json(["error": "Refresh the local Galaxy session"])) }
                    return reply(request, 200, shared)
                default: return reply(request, 404, Data())
                }
            }
        }
        // The saved identity is the digest of comma's paired tunnel link.
        let pinned = await ShareClient(load: lanComma(paired: link)).send(text: "x", settings: .init(address: "192.168.1.5", identity: identity, mode: nil), tunnel: nil)
        precondition(pinned == .started("Bellagio"))
        let action = log.last { $0.0.url!.path == "/api/navigation/action" }!
        precondition(action.1 && action.0.value(forHTTPHeaderField: "Cookie") == "galaxy_session=s2" && action.0.value(forHTTPHeaderField: "Origin") == "http://192.168.1.5:8082")
        precondition(action.0.value(forHTTPHeaderField: "Content-Type") == "application/json" && sessions == 2)
        precondition(log.allSatisfy { $0.1 })
        let body = try! JSONSerialization.jsonObject(with: action.0.httpBody!) as! [String: Any]
        precondition(body["action"] as? String == "share" && body["text"] as? String == "x" && body["revision"] as? String == "r1")

        // A different comma at the saved address is never sent the place; the tunnel is tried next.
        log = []; refreshOnce = false
        let other = ShareClient(load: { request, local in
            if !local {
                log.append((request, local))
                precondition(request.value(forHTTPHeaderField: "Cookie") == "galaxy_session=t0k3n")
                if request.httpMethod == "POST" { precondition(request.value(forHTTPHeaderField: "Origin") == "https://galaxy.firestar.link") }
                return request.url!.path.hasSuffix("/status") ? reply(request, 200, json(["revision": "r1"])) : reply(request, 200, shared)
            }
            return try await lanComma(paired: "https://galaxy.firestar.link/ZZZZZZZZZZZZZZZZ")(request, local)
        })
        let tunneled = await other.send(text: "x", settings: .init(address: "192.168.1.5", identity: identity, mode: "automatic"),
                                        tunnel: .init(url: link, cookie: "t0k3n"))
        let remote = log.filter { !$0.1 }
        precondition(tunneled == .started("Bellagio") && remote.count == 2 && remote[0].0.url!.absoluteString == link + "/api/navigation/status")
        precondition(!log.contains { $0.1 && $0.0.url!.path.hasPrefix("/api/navigation") })

        // Local Wi-Fi only never uses the tunnel; Bluetooth-only reaches neither.
        let unreachable = ShareClient(load: { _, _ in throw URLError(.cannotConnectToHost) })
        if case .unreachable = await unreachable.send(text: "x", settings: .init(address: "10.0.0.2", identity: nil, mode: "lan"), tunnel: .init(url: link, cookie: "t")) {} else { preconditionFailure() }
        var touched = false
        let none = ShareClient(load: { request, _ in touched = true; return reply(request, 500, Data()) })
        if case .unreachable = await none.send(text: "x", settings: .init(address: "10.0.0.2", identity: nil, mode: "bluetooth"), tunnel: .init(url: link, cookie: "t")) {} else { preconditionFailure() }
        precondition(!touched)

        // A tunnel redirect means its login expired.
        let expired = ShareClient(load: { request, _ in reply(request, 302, Data(), ["Location": "https://galaxy.firestar.link/login"]) })
        if case .unreachable = await expired.send(text: "x", settings: .init(), tunnel: .init(url: link, cookie: "t")) {} else { preconditionFailure() }
        // Refusals from comma end the attempt instead of trying the tunnel.
        let refusing = ShareClient(load: { request, local in
            precondition(local)
            if request.url!.path == "/api/auth/session" { return reply(request, 200, json(["authenticated": true, "localAccess": true]), ["Set-Cookie": "galaxy_session=s"]) }
            return request.httpMethod == "POST" ? reply(request, 400, json(["error": "Add a Mapbox token"])) : reply(request, 200, json(["revision": "r1"]))
        })
        let refused = await refusing.send(text: "x", settings: .init(address: "10.0.0.2"), tunnel: .init(url: link, cookie: "t"))
        precondition(refused == .refused("Add a Mapbox token"))
        print("Share relay regression passed")
    }
}
