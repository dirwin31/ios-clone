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
        print("Shared destination regression passed")
    }
}
