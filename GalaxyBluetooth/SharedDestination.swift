import Foundation

/// A place shared from Google or Apple Maps: its coordinates when the shared text carries them, else words to search for.
enum SharedDestination: Equatable {
    case place(name: String, latitude: Double, longitude: Double)
    case search(String)

    static let scheme = "starpilot"
    static let maxText = 8192

    /// The shared text from starpilot://share?text=…, as sent by the "Send to StarPilot" shortcut.
    static func text(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "share",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "text" || $0.name == "url" })?.value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxText))
    }

    static func shortLink(in text: String) -> URL? {
        first(#"https://(?:maps\.app\.goo\.gl|goo\.gl/maps)/[A-Za-z0-9_-]{1,64}"#, in: text).flatMap { URL(string: $0[0]) }
    }

    static func isGoogleMapsHost(_ host: String) -> Bool {
        host == "maps.app.goo.gl" || host == "goo.gl" || host == "google.com" || host.hasSuffix(".google.com")
    }

    /// Follows a Google Maps short link to the full link, which carries the coordinates. `next` gives a redirect's Location.
    static func resolve(_ text: String, next: (URL) async -> String?) async -> String {
        guard let short = shortLink(in: text) else { return text }
        var current = short
        for _ in 0..<5 {
            guard let location = await next(current), let following = URL(string: location, relativeTo: current)?.absoluteURL,
                  following.scheme == "https", let host = following.host?.lowercased(), isGoogleMapsHost(host),
                  following.absoluteString.count <= maxText else { break }
            current = following
        }
        return current == short ? text : text.replacingOccurrences(of: short.absoluteString, with: current.absoluteString)
    }

    /// Destination coordinates take precedence over a map's viewport (@lat,lng).
    static func parse(_ input: String) -> SharedDestination {
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
