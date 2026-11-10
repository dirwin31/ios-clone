import Foundation
import Security
import CryptoKit

/// What the share extension needs from the app, mirrored into the App Group; the tunnel login lives in the group's keychain.
enum ShareGroup {
    static let id = "group.link.galaxy.bluetooth.natehuby76"
    static let pendingNotification = "link.galaxy.bluetooth.natehuby76.share.pending"
    static let maxAge: TimeInterval = 12 * 3600

    struct Tunnel: Codable, Equatable { let url: String; let cookie: String }
    struct Pending: Codable, Equatable { let id: String; let text: String; let date: Date }
    struct Settings: Equatable { var address: String?, identity: String?, mode: String? }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
    private static let keys = (address: "galaxy.lan.address", identity: "galaxy.comma.identity", mode: "galaxy.connection.mode",
                               pending: "share.pending", search: "share.search")

    static var settings: Settings {
        Settings(address: defaults?.string(forKey: keys.address), identity: defaults?.string(forKey: keys.identity), mode: defaults?.string(forKey: keys.mode))
    }
    static func mirror(_ value: Settings) {
        guard let defaults, value != settings else { return }
        for (key, item) in [(keys.address, value.address), (keys.identity, value.identity), (keys.mode, value.mode)] {
            if let item, !item.isEmpty { defaults.set(item, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private static var tunnelQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "link.galaxy.share.tunnel",
         kSecAttrAccount as String: "comma", kSecAttrAccessGroup as String: id]
    }
    static var tunnel: Tunnel? {
        var query = tunnelQuery; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Tunnel.self, from: data)
    }
    static func mirror(tunnel value: Tunnel?) {
        guard value != tunnel else { return }
        guard let value, let data = try? JSONEncoder().encode(value) else { SecItemDelete(tunnelQuery as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(tunnelQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(tunnelQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    /// One waiting share; a newer one replaces it.
    static func queue(_ text: String, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Pending(id: UUID().uuidString, text: text, date: now)) else { return }
        defaults?.set(data, forKey: keys.pending)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(pendingNotification as CFString), nil, nil, true)
    }
    static func pending(now: Date = Date()) -> Pending? {
        guard let data = defaults?.data(forKey: keys.pending), let value = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        guard now.timeIntervalSince(value.date) < maxAge, value.date <= now.addingTimeInterval(60) else { clear(value.id); return nil }
        return value
    }
    /// Only the share that was delivered is cleared, never one queued meanwhile.
    static func clear(_ id: String) {
        if let data = defaults?.data(forKey: keys.pending), let value = try? JSONDecoder().decode(Pending.self, from: data), value.id != id { return }
        defaults?.removeObject(forKey: keys.pending)
    }

    /// Text comma could not place, for Galaxy's search the next time the app opens.
    static func stashSearch(_ text: String) { defaults?.set(text, forKey: keys.search) }
    static func takeSearch() -> String? {
        guard let text = defaults?.string(forKey: keys.search) else { return nil }
        defaults?.removeObject(forKey: keys.search)
        return text
    }
}

/// A slim comma client for the share extension: the saved home-network address, then the tunnel. Bluetooth stays with the app.
struct ShareClient {
    typealias Load = (URLRequest, _ local: Bool) async throws -> (Data, HTTPURLResponse)
    var load: Load = ShareClient.fetch
    var timeout: TimeInterval = 4
    /// comma may follow short links and geocode before it answers.
    var actionTimeout: TimeInterval = 25

    final class Route {
        let base: URL, origin: String, local: Bool
        var cookie: String
        init(base: URL, origin: String, local: Bool, cookie: String) { self.base = base; self.origin = origin; self.local = local; self.cookie = cookie }
    }

    func send(text: String, settings: ShareGroup.Settings, tunnel: ShareGroup.Tunnel?) async -> DestinationSender.Outcome {
        var result = DestinationSender.Outcome.unreachable("comma is not reachable")
        let mode = settings.mode ?? "automatic"
        if mode != "bluetooth", let address = settings.address, let base = Self.lanEndpoint(address) {
            do {
                let route = Route(base: base, origin: base.absoluteString, local: true, cookie: try await session(base))
                if try await verified(route, identity: settings.identity) { result = await share(text, over: route) }
                else { result = .unreachable("A different comma answered at the saved address") }
            } catch { result = .unreachable(error.localizedDescription) }
            if case .unreachable = result {} else { return result }
        }
        if mode == "automatic", let tunnel, let base = Self.tunnelEndpoint(tunnel.url), !Task.isCancelled {
            return await share(text, over: Route(base: base, origin: "https://galaxy.firestar.link", local: false, cookie: "galaxy_session=" + tunnel.cookie))
        }
        return result
    }

    private func share(_ text: String, over route: Route) async -> DestinationSender.Outcome {
        await DestinationSender.share(text: text, status: { try await call(route, "/api/navigation/status") }, action: {
            try await call(route, "/api/navigation/action", body: try JSONSerialization.data(withJSONObject: $0))
        })
    }

    func call(_ route: Route, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        for attempt in 0...1 {
            var request = URLRequest(url: URL(string: route.base.absoluteString + path)!, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: body == nil ? timeout : actionTimeout)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.setValue(route.cookie, forHTTPHeaderField: "Cookie")
            if let body {
                request.httpBody = body
                request.setValue(route.origin, forHTTPHeaderField: "Origin")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await load(request, route.local)
            if route.local, attempt == 0, response.statusCode == 401,
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "Refresh the local Galaxy session" {
                route.cookie = try await session(route.base)
                continue
            }
            if !route.local, (300..<400).contains(response.statusCode) { return (401, data) }
            return (response.statusCode, data)
        }
        return (401, Data())
    }

    /// The same local session the app opens: comma grants it only to clients on its own network.
    func session(_ base: URL) async throws -> String {
        let request = URLRequest(url: base.appendingPathComponent("api/auth/session"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await load(request, true)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { if let key = $1.key as? String { $0[key] = String(describing: $1.value) } }
        guard response.statusCode == 200, json?["authenticated"] as? Bool == true, json?["localAccess"] as? Bool == true,
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base).first(where: { $0.name == "galaxy_session" && !$0.value.isEmpty }) else {
            throw URLError(.userAuthenticationRequired)
        }
        return "galaxy_session=" + cookie.value
    }

    /// The comma at the saved address must be the one the app paired with.
    func verified(_ route: Route, identity: String?) async throws -> Bool {
        guard let identity, !identity.isEmpty else { return true }
        if identity.hasPrefix("galaxy:") {
            let (code, data) = try await call(route, "/api/galaxy/status")
            guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["paired"] as? Bool == true,
                  let text = json["url"] as? String, let url = Self.tunnelEndpoint(text) else { return false }
            return identity == "galaxy:" + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let (code, data) = try await call(route, "/data/runtime.json")
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1, json["monitor"] as? String == "local" else { return false }
        return json["instance"] as? String == identity
    }

    static func lanEndpoint(_ address: String) -> URL? {
        var input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("http://") { input = String(input.dropFirst(7)) }
        if input.hasSuffix("/") { input.removeLast() }
        if input.hasSuffix(":8082") { input = String(input.dropLast(5)) }
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && String(Int($0) ?? -1) == $0 }),
              let a = Int(parts[0]), let b = Int(parts[1]), parts.allSatisfy({ (0...255).contains(Int($0) ?? -1) }),
              a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) else { return nil }
        return URL(string: "http://\(parts.joined(separator: ".")):8082")
    }

    static func tunnelEndpoint(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "galaxy.firestar.link", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/[A-Za-z0-9]{16}/?$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://galaxy.firestar.link/" + url.path.split(separator: "/")[0])
    }

    /// Ephemeral, cookie-less and redirect-free; local requests never leave over cellular.
    static func fetch(_ request: URLRequest, local: Bool) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.connectionProxyDictionary = [:]
        config.allowsCellularAccess = !local
        config.timeoutIntervalForResource = request.timeoutInterval * 2
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 1 << 20 else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
