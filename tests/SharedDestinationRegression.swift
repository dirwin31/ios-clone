import Foundation

@main struct SharedDestinationRegression {
    static func place(_ text: String) -> (String, Double, Double)? {
        if case let .place(name, latitude, longitude) = SharedDestination.parse(text) { return (name, latitude, longitude) }
        return nil
    }
    static func main() async {
        for text in ["https://maps.google.com/@12.3,-45.6,15z", "https://maps.google.com/?q=12.3,-45.6", "geo:12.3,-45.6(Home)",
                     "google.navigation:q=12.3,-45.6", "https://maps.google.com/?daddr=12.3,-45.6",
                     "https://maps.google.com/@1,2,15z/data=!3d12.3!4d-45.6", "https://maps.apple.com/?ll=12.3,-45.6&q=Cafe",
                     "https://maps.google.com/?q=12.3%2C-45.6"] {
            guard let (_, latitude, longitude) = place(text) else { preconditionFailure(text) }
            precondition(latitude == 12.3 && longitude == -45.6, text)
        }
        precondition(place("geo:12.3,-45.6(Home)")?.0 == "Home")
        precondition(place("https://maps.apple.com/?ll=12.3,-45.6&q=Cafe")?.0 == "Cafe")
        precondition(place("Bellagio\n3600 S Las Vegas Blvd\nhttps://www.google.com/maps/place/Bellagio+Hotel/@36.11,-115.17,17z/data=!3d36.1126!4d-115.1767")?.0 == "Bellagio Hotel")
        precondition(place("geo:123,456") == nil)
        precondition(SharedDestination.parse("geo:0,0?q=10+Main+Street") == .search("10 Main Street"))
        precondition(SharedDestination.parse("Bellagio\n3600 S Las Vegas Blvd\nhttps://maps.app.goo.gl/AbC123") == .search("Bellagio, 3600 S Las Vegas Blvd"))

        let share = URL(string: "starpilot://share?text=Bellagio%0Ahttps%3A%2F%2Fmaps.app.goo.gl%2FAbC123")!
        precondition(SharedDestination.text(from: share) == "Bellagio\nhttps://maps.app.goo.gl/AbC123")
        precondition(SharedDestination.text(from: URL(string: "starpilot-discord://callback?text=x")!) == nil)
        precondition(SharedDestination.text(from: URL(string: "starpilot://share?text=%20")!) == nil)

        let full = "https://www.google.com/maps/place/Bellagio/@36.11,-115.17,17z/data=!3d36.1126!4d-115.1767"
        let hops = ["https://maps.app.goo.gl/AbC123": "https://maps.google.com/?redirect=1", "https://maps.google.com/?redirect=1": full]
        let resolved = await SharedDestination.resolve("Bellagio\nhttps://maps.app.goo.gl/AbC123") { hops[$0.absoluteString] }
        precondition(resolved == "Bellagio\n" + full)
        precondition(place(resolved)?.1 == 36.1126)
        let evil = await SharedDestination.resolve("https://maps.app.goo.gl/AbC123") { _ in "https://evil.example/maps?q=1,2" }
        precondition(evil == "https://maps.app.goo.gl/AbC123")
        let plain = await SharedDestination.resolve("https://maps.app.goo.gl/AbC123") { _ in "http://www.google.com/maps" }
        precondition(plain == "https://maps.app.goo.gl/AbC123")
        var asked = false
        _ = await SharedDestination.resolve("Starbucks") { _ in asked = true; return nil }
        precondition(!asked)
        let waze = "https://www.waze.com/ul?ll=43.65%2C-79.38&navigate=yes"
        precondition(place(waze)?.1 == 43.65 && place(waze)?.2 == -79.38)
        precondition(place("waze://?ll=43.65,-79.38")?.1 == 43.65)
        precondition(SharedDestination.parse("https://waze.com/ul?q=10%20Main%20Street") == .search("10 Main Street"))
        precondition(SharedDestination.wazeURL(in: "https://waze.com.evil.example/ul?ll=1,2") == nil)
        precondition(SharedDestination.wazeDestination(URL(string: "https://waze.com/ul?favorite=home")!) == nil)
        precondition(SharedDestination.wazeDestination(URL(string: "https://waze.com/ul?ll=91,2")!) == nil)
        let wazeShort = "https://waze.com/ul/opaque"
        let wazeResolved = await SharedDestination.resolve(wazeShort) { _ in waze }
        precondition(wazeResolved == waze)
        let wazeBlocked = await SharedDestination.resolve(wazeShort) { _ in "https://evil.example/ul?ll=1,2" }
        precondition(wazeBlocked == wazeShort)
        let wazeDowngrade = await SharedDestination.resolve(wazeShort) { _ in "http://waze.com/ul?ll=1,2" }
        precondition(wazeDowngrade == wazeShort)
        func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let there: [String: Any] = ["latitude": 36.1126, "longitude": -115.1767]
        var statuses = [json(["revision": "r1", "enabled": false, "hasKey": true])]
        var replies = [json(["revision": "r2", "enabled": true, "hasKey": true]), json(["revision": "r3", "enabled": true, "hasKey": true, "destination": there])]
        var sent: [[String: Any]] = []
        try! await DestinationSender.start(name: "Bellagio", latitude: 36.1126, longitude: -115.1767,
                                           status: { (200, statuses.removeFirst()) }, action: { sent.append($0); return (200, replies.removeFirst()) })
        precondition(sent.map { $0["action"] as? String } == ["configure", "select"] && sent[1]["revision"] as? String == "r2")

        statuses = [json(["revision": "r1", "enabled": true, "hasKey": true]), json(["revision": "r2", "enabled": true, "hasKey": true, "destination": there])]
        sent = []
        try! await DestinationSender.start(name: "Bellagio", latitude: 36.1126, longitude: -115.1767,
                                           status: { (200, statuses.removeFirst()) }, action: { sent.append($0); return (409, Data()) })
        precondition(sent.count == 1)

        do {
            try await DestinationSender.start(name: "Bellagio", latitude: 1, longitude: 2,
                                              status: { (200, json(["revision": "r1", "enabled": true, "hasKey": false])) }, action: { _ in preconditionFailure() })
            preconditionFailure("no token")
        } catch let failure as DestinationSender.Failure { precondition(failure == .refused("Add a Mapbox token in Galaxy navigation first")) }
        catch { preconditionFailure("\(error)") }
        do {
            try await DestinationSender.start(name: "Bellagio", latitude: 1, longitude: 2,
                                              status: { (403, json(["error": "Remote Galaxy request denied"])) }, action: { _ in preconditionFailure() })
            preconditionFailure("denied")
        } catch let failure as DestinationSender.Failure { precondition(failure == .unreachable("Remote Galaxy request denied")) }
        catch { preconditionFailure("\(error)") }

        let ready = json(["revision": "r1", "enabled": true, "hasKey": true])
        var wazeActions: [[String: Any]] = []
        let wazeOutcome = await DestinationSender.share(text: waze, status: { (200, ready) }, action: { payload in
            wazeActions.append(payload)
            return (200, json(["enabled": true, "hasKey": true, "destination": ["latitude": 43.65, "longitude": -79.38]]))
        })
        precondition(wazeOutcome == .started("Shared destination"))
        precondition(wazeActions.count == 1 && wazeActions[0]["action"] as? String == "select")
        let opaque = await DestinationSender.share(text: wazeShort, status: { preconditionFailure("Do not send an opaque Waze link") }, action: { _ in preconditionFailure() })
        if case .refused = opaque {} else { preconditionFailure() }
        let named = "Bellagio\nhttps://www.google.com/maps/place/Bellagio,+3600+S+Las+Vegas+Blvd/data=!4m2!3m1!1s0x1:0x2"
        sent = []
        var outcome = await DestinationSender.share(text: "  " + named + "\n", status: { (200, ready) }, action: {
            sent.append($0); return (200, json(["revision": "r2", "shared": ["name": "Bellagio", "latitude": 36.1126, "longitude": -115.1767]]))
        })
        precondition(outcome == .started("Bellagio"))
        precondition(sent.count == 1 && sent[0]["action"] as? String == "share" && sent[0]["revision"] as? String == "r1" && sent[0]["text"] as? String == named)

        var reads = 0
        sent = []
        outcome = await DestinationSender.share(text: named, status: { reads += 1; return (200, json(["revision": "r\(reads)"])) }, action: {
            sent.append($0)
            return sent.count == 1 ? (409, json(["error": "Navigation changed"])) : (200, json(["shared": ["name": "Bellagio", "latitude": 1.0, "longitude": 2.0]]))
        })
        precondition(outcome == .started("Bellagio") && reads == 2 && sent.map { $0["revision"] as? String } == ["r1", "r2"])
        outcome = await DestinationSender.share(text: named, status: { (200, ready) }, action: { _ in (409, Data()) })
        precondition(outcome == .unreachable("Navigation kept changing on comma"))

        outcome = await DestinationSender.share(text: "Starbucks", status: { (200, ready) }, action: { _ in (400, json(["error": "Choose a place", "query": "Starbucks"])) })
        precondition(outcome == .needsSearch("Starbucks"))
        outcome = await DestinationSender.share(text: named, status: { (200, ready) }, action: { _ in (400, json(["error": "Add a Mapbox token in Galaxy navigation first"])) })
        precondition(outcome == .refused("Add a Mapbox token in Galaxy navigation first"))
        outcome = await DestinationSender.share(text: named, status: { (200, ready) }, action: { _ in (401, json(["error": "Sign in"])) })
        precondition(outcome == .unreachable("Sign in to Galaxy again"))
        outcome = await DestinationSender.share(text: named, status: { (401, Data()) }, action: { _ in preconditionFailure() })
        precondition(outcome == .unreachable("Sign in to Galaxy again"))
        outcome = await DestinationSender.share(text: named, status: { throw URLError(.timedOut) }, action: { _ in preconditionFailure() })
        if case .unreachable = outcome {} else { preconditionFailure("network failure") }
        outcome = await DestinationSender.share(text: named, status: { (200, ready) }, action: { _ in (200, json(["revision": "r2"])) })
        precondition(outcome == .unreachable("comma did not confirm the destination"))

        // Older commas reject `share`; coordinates are parsed here, else Galaxy searches.
        let old = json(["error": "Invalid navigation action"])
        statuses = [ready, ready]
        sent = []
        outcome = await DestinationSender.share(text: "https://maps.google.com/?q=36.1126,-115.1767", status: { (200, statuses.removeFirst()) }, action: {
            sent.append($0); return $0["action"] as? String == "share" ? (400, old) : (200, json(["revision": "r2", "enabled": true, "hasKey": true, "destination": there]))
        })
        precondition(outcome == .started("Shared destination") && sent.map { $0["action"] as? String } == ["share", "select"])
        outcome = await DestinationSender.share(text: named, status: { (200, ready) }, action: { precondition($0["action"] as? String == "share"); return (400, old) })
        precondition(outcome == .needsSearch(named))
        outcome = await DestinationSender.share(text: "geo:1,2", status: { (200, json(["revision": "r1", "enabled": true, "hasKey": false])) }, action: { _ in (400, old) })
        precondition(outcome == .refused("Add a Mapbox token in Galaxy navigation first"))

        let long = String(repeating: "é", count: SharedDestination.maxText + 10)
        _ = await DestinationSender.share(text: long, status: { (200, ready) }, action: { sent.append($0); return (400, json(["query": ""])) })
        precondition((sent.last?["text"] as? String)?.unicodeScalars.count == SharedDestination.maxText)
        print("Shared destination regression passed")
    }
}
