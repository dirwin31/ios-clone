import MapKit

@main
struct MappedJunctionRegression {
    static func main() throws {
        let points = [[-80.0, 43.0], [-80.0, 43.001], [-80.0, 43.002]]
        let sign: [String: Any] = ["geometry_index": 1, "location": points[1], "stop_sign": true]
        let light: [String: Any] = ["geometry_index": 1, "location": points[1], "traffic_signal": true]
        func decode(_ intersections: Any) throws -> PhoneRoute {
            let shape = ["coordinates": points]
            let step: [String: Any] = ["geometry": shape, "distance": 200, "duration": 20,
                "maneuver": ["type": "continue", "instruction": "Continue"], "intersections": intersections]
            let route: [String: Any] = ["distance": 200, "duration": 20, "geometry": shape,
                "legs": [["steps": [step], "summary": "Test"]]]
            let data = try JSONSerialization.data(withJSONObject: ["routes": [route]])
            return try PhoneRoute.decodeMapboxRoutes(data)[0]
        }
        func fix(_ lat: Double, _ lon: Double = -80, course: Double = 0, age: Double = 0, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 5, course: course, courseAccuracy: 10, speed: 9, speedAccuracy: 1,
                       timestamp: Date().addingTimeInterval(-age))
        }
        let route = try decode([sign, light, sign, "malformed"] as [Any])
        for bearing in [nil, 0, 270] as [Int?] {
            let url = try PhoneRoute.mapboxURL(from: fix(43).coordinate, to: fix(43.002).coordinate, alternatives: false,
                                              token: "test", bearing: bearing)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let value = query?.first { $0.name == "bearings" }?.value
            precondition(value == bearing.map { "\($0),45;" })
        }
        precondition(PhoneRoute.movingCourse(fix(43.0005, course: 359.8)) == 0)
        precondition(PhoneRoute.movingCourse(fix(43.0005, age: 6)) == nil)
        precondition(PhoneRoute.movingCourse(fix(43.0005, accuracy: 50)) == nil)
        precondition(!route.offCourse(at: fix(43.0005)))
        precondition(route.offCourse(at: fix(43.0005, course: 180)), "Reversing along the line must trigger rerouting")
        precondition(route.offCourse(at: fix(43.0005, -80.002)))
        precondition(!route.offCourse(at: fix(43.0005, -80.002, age: 10)))
        precondition(route.junctions.count == 1)
        let observed = route.upcomingJunction(at: fix(43.0005))
        precondition(observed?.labels == "stop sign, traffic light")
        precondition((52...59).contains(observed?.meters ?? 0))
        precondition(route.upcomingJunction(at: fix(43.0005, course: 180)) == nil)
        precondition(route.upcomingJunction(at: fix(43.001, -80.0006, course: 90)) == nil)
        precondition(route.upcomingJunction(at: fix(43.0014)) == nil)
        precondition(route.upcomingJunction(at: fix(43.0005, age: 6)) == nil)
        precondition(route.upcomingJunction(at: fix(43.0005, accuracy: 50)) == nil)
        let invalid = try decode([["geometry_index": 7, "location": points[1], "yield_sign": true]])
        let unknown = try decode("unavailable")
        precondition(invalid.junctions.isEmpty && unknown.junctions.isEmpty)
        guard let annotated = route.commaPreview, let plain = unknown.commaPreview else { preconditionFailure("Missing route handoff") }
        let payload = try JSONSerialization.jsonObject(with: annotated) as! NSDictionary
        let baseline = try JSONSerialization.jsonObject(with: plain) as! NSDictionary
        precondition(payload.isEqual(baseline))
        print("Mapped junction replay checks passed")
    }
}
