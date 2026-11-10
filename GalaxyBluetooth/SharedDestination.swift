import Foundation

/// A place shared from Google Maps, Apple Maps or Waze.
enum SharedDestination: Equatable {
    case place(name: String, latitude: Double, longitude: Double)
    case search(String)

    static let scheme = "starpilot"
    static let maxText = 8192

    /// The shared text from starpilot://share?text=….
    static func text(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "share",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "text" || $0.name == "url" })?.value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxText))
    }

    static func shortLink(in text: String) -> URL? {
        if let link = first(#"https://(?:maps\.app\.goo\.gl|goo\.gl/maps)/[A-Za-z0-9_-]{1,64}"#, in: text) {
            return URL(string: link[0])
        }
        return wazeURL(in: text).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    static func isWazeHost(_ host: String) -> Bool { ["waze.com", "www.waze.com", "waze.page.link"].contains(host) }

    static func wazeURL(in text: String) -> URL? {
        guard let raw = first(#"(?:https://|waze://)[^\s<>\"]+"#, in: text)?[0],
              let url = URL(string: raw), url.user == nil, url.password == nil, url.port == nil,
              url.scheme == "waze" || isWazeHost(url.host?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Never interpret Waze home/work favorites or opaque share tokens as an address.
    static func wazeDestination(_ url: URL) -> SharedDestination? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "q" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ll = items.first(where: { $0.name == "ll" })?.value {
            let parts = ll.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
               lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
                return .place(name: query?.isEmpty == false ? String(query!.prefix(120)) : "Shared destination", latitude: lat, longitude: lon)
            }
            return nil
        }
        if let query, !query.isEmpty { return .search(String(query.prefix(200))) }
        return nil
    }

    static func isGoogleMapsHost(_ host: String) -> Bool {
        host == "maps.app.goo.gl" || host == "goo.gl" || host == "google.com" || host.hasSuffix(".google.com")
    }

    /// Follows a Google Maps short link to the full link, which carries the coordinates. `next` gives a redirect's Location.
    static func resolve(_ text: String, next: (URL) async -> String?) async -> String {
        guard let short = shortLink(in: text) else { return text }
        let waze = isWazeHost(short.host?.lowercased() ?? "")
        var current = short
        for _ in 0..<5 {
            if waze, wazeDestination(current) != nil { break }
            guard let location = await next(current), let following = URL(string: location, relativeTo: current)?.absoluteURL,
                  following.scheme == "https", following.user == nil, following.password == nil, following.port == nil,
                  let host = following.host?.lowercased(), waze ? isWazeHost(host) : isGoogleMapsHost(host),
                  following.absoluteString.count <= maxText else { break }
            current = following
        }
        return current == short ? text : text.replacingOccurrences(of: short.absoluteString, with: current.absoluteString)
    }

    /// Destination coordinates take precedence over a map's viewport (@lat,lng).
    static func parse(_ input: String) -> SharedDestination {
        if let waze = wazeURL(in: input) { return wazeDestination(waze) ?? .search("") }
        var text = String(input.prefix(maxText)).trimmingCharacters(in: .whitespacesAndNewlines)
        text = (text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text)
        let number = #"(-?\d+(?:\.\d+)?)"#
        let patterns = [#"!3d"# + number + #"!4d"# + number,
                        #"[?&:](?:q|query|daddr|destination|ll)="# + number + #",\s*"# + number,
                        #"geo:"# + number + #",\s*"# + number,
                        #"@"# + number + #",\s*"# + number]
        for pattern in patterns {
            guard let match = first(pattern, in: text), let latitude = Double(match[1]), let longitude = Double(match[2]),
                  abs(latitude) <= 90, abs(longitude) <= 180 else { continue }
            // geo:0,0?q=an address is a search, not a destination in the ocean.
            if match[0].hasPrefix("geo:0,0"), first(#"[?&:]q="#, in: text) != nil { continue }
            return .place(name: label(text) ?? "Shared destination", latitude: latitude, longitude: longitude)
        }
        if let query = first(#"[?&:](?:q|query|daddr|destination)=([^&#\n]+)"#, in: text)?[1] {
            return .search(String(query.trimmingCharacters(in: .whitespaces).prefix(200)))
        }
        return .search(String(words(text).prefix(200)))
    }

    private static func label(_ text: String) -> String? {
        if let name = first(#"\(([^()\n]{1,120})\)"#, in: text)?[1] { return name }
        if let name = first(#"/place/([^/@?#\n]{1,120})"#, in: text)?[1] { return name.trimmingCharacters(in: .whitespaces) }
        if let name = first(#"[?&]q=([^&#\n]{1,120})"#, in: text)?[1], Double(name.split(separator: ",").first ?? "") == nil { return name }
        let lead = words(text).split(separator: ",").first.map(String.init) ?? ""
        return lead.isEmpty ? nil : String(lead.prefix(120))
    }

    /// The shared text without its links: Google's "Name\nAddress\nlink" becomes "Name, Address".
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ").filter { !$0.contains("://") }.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// One request that reports a redirect's Location instead of following it; the body is never used.
final class RedirectProbe: NSObject, URLSessionTaskDelegate {
    func location(of url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: self),
              let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) else { return nil }
        return http.value(forHTTPHeaderField: "Location")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Sets comma's destination and starts the route: read the status, turn navigation on if needed, then select the place.
enum DestinationSender {
    enum Failure: Error, Equatable {
        /// Galaxy answered and said no; another route to comma would get the same answer.
        case refused(String)
        case unreachable(String)
    }
    struct State {
        let code: Int
        var revision = "", enabled = false, hasKey = false
        var latitude: Double?, longitude: Double?, error: String?
        init(code: Int, data: Data) {
            self.code = code
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            revision = json["revision"] as? String ?? ""; enabled = json["enabled"] as? Bool ?? false; hasKey = json["hasKey"] as? Bool ?? false
            let destination = json["destination"] as? [String: Any]
            latitude = destination?["latitude"] as? Double; longitude = destination?["longitude"] as? Double; error = json["error"] as? String
        }
        func at(_ latitude: Double, _ longitude: Double) -> Bool {
            guard let a = self.latitude, let b = self.longitude else { return false }
            return abs(a - latitude) < 1e-5 && abs(b - longitude) < 1e-5
        }
    }

    static func start(name: String, latitude: Double, longitude: Double,
                      status: () async throws -> (Int, Data), action: ([String: Any]) async throws -> (Int, Data)) async throws {
        var state = try checked(try await status())
        guard state.hasKey else { throw Failure.refused("Add a Mapbox token in Galaxy navigation first") }
        if state.enabled && state.at(latitude, longitude) { return }
        if !state.enabled { state = try checked(try await action(["action": "configure", "revision": state.revision, "patch": ["enabled": true]])) }
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        for _ in 0..<2 {
            let reply = try await action(["action": "select", "revision": state.revision,
                                          "destination": ["name": label.isEmpty ? "Shared destination" : label, "latitude": latitude, "longitude": longitude]])
            if reply.0 != 409 {
                guard try checked(reply).at(latitude, longitude) else { throw Failure.unreachable("comma did not confirm the destination") }
                return
            }
            // Another phone or Galaxy changed navigation; a select that already landed is not sent twice.
            state = try checked(try await status())
            if state.enabled && state.at(latitude, longitude) { return }
        }
        throw Failure.unreachable("Navigation kept changing on comma")
    }

    enum Outcome: Equatable {
        case started(String)
        /// comma could not pick one place; the text goes to Galaxy's navigation search.
        case needsSearch(String)
        case refused(String)
        case unreachable(String)
    }

    static func capped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(SharedDestination.maxText)))
    }

    /// comma reads the shared text itself (coordinates, else its geocoder). Older commas without `share` get the place parsed here.
    static func share(text: String, status: () async throws -> (Int, Data), action: ([String: Any]) async throws -> (Int, Data)) async -> Outcome {
        let text = capped(text)
        if let waze = SharedDestination.wazeURL(in: text) {
            guard let destination = SharedDestination.wazeDestination(waze) else {
                return .refused("This Waze link does not include a destination we can read. Share the place's address or a link with coordinates instead.")
            }
            switch destination {
            case .place:
                // The existing coordinate endpoint also works on older comma software.
                return await legacy(text: text, status: status, action: action)
            case .search(let query):
                return await share(text: query, status: status, action: action)
            }
        }
        do {
            var state = try checked(try await status())
            for _ in 0..<2 {
                let reply = try await action(["action": "share", "revision": state.revision, "text": text])
                let json = (try? JSONSerialization.jsonObject(with: reply.1)) as? [String: Any]
                switch reply.0 {
                case 200:
                    guard let shared = json?["shared"] as? [String: Any], let name = shared["name"] as? String else {
                        return .unreachable("comma did not confirm the destination")
                    }
                    return .started(name.isEmpty ? "Shared destination" : name)
                case 409:
                    state = try checked(try await status())
                case 400 where json?["query"] != nil:
                    return .needsSearch(text)
                case 400 where json?["error"] as? String == "Invalid navigation action":
                    return await legacy(text: text, status: status, action: action)
                case 400:
                    return .refused(json?["error"] as? String ?? "Galaxy refused the destination")
                case 401:
                    return .unreachable("Sign in to Galaxy again")
                default:
                    return .unreachable(json?["error"] as? String ?? "Galaxy returned HTTP \(reply.0)")
                }
            }
            return .unreachable("Navigation kept changing on comma")
        } catch Failure.refused(let message) { return .refused(message) }
        catch Failure.unreachable(let message) { return .unreachable(message) }
        catch { return .unreachable(error.localizedDescription) }
    }

    private static func legacy(text: String, status: () async throws -> (Int, Data), action: ([String: Any]) async throws -> (Int, Data)) async -> Outcome {
        guard case let .place(name, latitude, longitude) = SharedDestination.parse(text) else { return .needsSearch(text) }
        do {
            try await start(name: name, latitude: latitude, longitude: longitude, status: status, action: action)
            return .started(name)
        } catch Failure.refused(let message) { return .refused(message) }
        catch Failure.unreachable(let message) { return .unreachable(message) }
        catch { return .unreachable(error.localizedDescription) }
    }

    private static func checked(_ reply: (Int, Data)) throws -> State {
        let state = State(code: reply.0, data: reply.1)
        switch reply.0 {
        case 200: return state
        case 400: throw Failure.refused(state.error ?? "Galaxy refused the destination")
        case 401: throw Failure.unreachable("Sign in to Galaxy again")
        default: throw Failure.unreachable(state.error ?? "Galaxy returned HTTP \(reply.0)")
        }
    }
}
