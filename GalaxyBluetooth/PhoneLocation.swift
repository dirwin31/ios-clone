import CoreLocation
import Foundation

/// Shares fresh fixes up to 5 Hz on Local Wi-Fi, retaining the existing cadence on other routes.
/// Galaxy's navigation GPS source setting controls whether comma prefers this phone or uses it as backup.
@MainActor
final class PhoneLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let path = "/api/companion/location"
    nonisolated static let maxAgeMs = 2000.0

    @Published private(set) var sharing = UserDefaults.standard.bool(forKey: "galaxy.phoneGps")
    @Published private(set) var status = ""
    var onEvent: ((String) -> Void)?
    private var offered = 0
    private var skipped = 0
    private var accepted = 0
    private var failed = 0
    private var skipReasons: [String: Int] = [:]
    private var uploadSequence = 0
    private var consecutiveFailures = 0
    private var lastSuccess: Date?
    private var successDiagnostics = DiagnosticSuccessSampler()
    var diagnosticSummary: String {
        let reasons = skipReasons.keys.sorted().map { "\($0)=\(skipReasons[$0] ?? 0)" }.joined(separator: ", ")
        let age = lastSuccess.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none"
        return "offered=\(offered); skipped=\(skipped); accepted=\(accepted); failed=\(failed); consecutive failures=\(consecutiveFailures); last success age=\(age); skips=[\(reasons)]; pending=\(pending != nil); in flight=\(sending); permission=\(manager?.authorizationStatus.rawValue ?? -1); upload interval=\(transport()?.localRefreshDelay ?? 0.9)s"
    }
    private func recordSkip(_ reason: String) { skipped += 1; skipReasons[reason, default: 0] += 1 }
    var onSharingChanged: ((Bool) -> Void)?
    private let transport: () -> (any GalaxyRequestTransport)?
    private let manager: CLLocationManager?
    private let diagnosticClock: () -> TimeInterval
    private var sending = false
    private var pending: CLLocation?
    private var lastSent = Date.distantPast
    private var lastLocalFix = Date.distantPast

    init(transport: @escaping () -> (any GalaxyRequestTransport)?, manager: CLLocationManager? = CLLocationManager(),
         diagnosticClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.manager = manager
        self.diagnosticClock = diagnosticClock
        super.init()
        guard let manager else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = !UserDefaults.standard.bool(forKey: "galaxy.location.hideIndicator")
        #endif
        if sharing { begin() }
    }

    func setSharing(_ value: Bool) {
        guard value != sharing else { return }
        onEvent?("Sharing changed: \(value)")
        sharing = value
        UserDefaults.standard.set(value, forKey: "galaxy.phoneGps")
        if value { begin() } else { manager?.stopUpdatingLocation(); status = "" }
        onSharingChanged?(value)
    }

    func setHideBackgroundIndicator(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: "galaxy.location.hideIndicator")
        #if os(iOS)
        manager?.showsBackgroundLocationIndicator = !hide
        if hide && sharing && manager?.authorizationStatus == .authorizedWhenInUse { manager?.requestAlwaysAuthorization() }
        #endif
    }

    private func begin() {
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Allow location to share GPS."; manager.requestAlwaysAuthorization()
        case .denied, .restricted: status = "Location is off for this app. Turn it on in iPhone Settings."
        default:
            #if os(iOS)
            manager.allowsBackgroundLocationUpdates = true
            #endif
            status = "Waiting for GPS"
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onEvent?("Authorization changed: \(manager.authorizationStatus.rawValue)")
        if sharing { begin() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { await deliver(location) }
    }

    /// One upload at a time; newer callbacks replace pending fixes instead of building a queue.
    func deliver(_ location: CLLocation, now: Date = Date()) async {
        offered += 1
        guard sharing else { recordSkip("sharing-off"); return }
        if sending { pending = location; recordSkip("coalesced"); return }
        let currentTransport = transport()
        let localDelay = currentTransport?.localRefreshDelay
        guard now.timeIntervalSince(lastSent) >= (localDelay ?? 0.9) else { recordSkip("throttled"); return }
        if localDelay != nil, location.timestamp <= lastLocalFix { recordSkip("duplicate-fix"); return }
        guard let body = Self.payload(location, now: now) else { recordSkip("invalid-fix"); onEvent?("Fix rejected: age=\(now.timeIntervalSince(location.timestamp)); accuracy=\(location.horizontalAccuracy)"); status = "Waiting for GPS"; return }
        guard let transport = currentTransport, transport.connected else { recordSkip("disconnected"); status = "Waiting for comma"; return }
        if localDelay != nil {
            lastLocalFix = location.timestamp
            lastSent = now
        }
        let startedUptime = diagnosticClock()
        uploadSequence += 1
        let uploadID = uploadSequence
        sending = true
        defer {
            sending = false
            if let next = pending {
                pending = nil
                Task { await deliver(next) }
            }
        }
        do {
            let response = try await transport.request(path: Self.path, method: "POST", headers: ["Content-Type": "application/json"], body: body)
            let completedUptime = diagnosticClock()
            let elapsed = completedUptime - startedUptime
            let recovered = consecutiveFailures > 0
            if response.status == 200 { accepted += 1; consecutiveFailures = 0; lastSuccess = Date() }
            else { failed += 1; consecutiveFailures += 1 }
            if let onEvent, let sampled = successDiagnostics.take(
                routineSuccess: response.status == 200 && elapsed < 2 && !Task.isCancelled && !recovered,
                now: completedUptime) {
                onEvent("Upload #\(uploadID) finished: HTTP \(response.status); \(SecretGoodGalaxy.responseDiagnostic(status: response.status, encodedBody: response.body)); elapsed=\(elapsed)s; fix age at offer=\(now.timeIntervalSince(location.timestamp))s; accuracy=\(location.horizontalAccuracy)m; payload bytes=\(body.count); consecutive failures=\(consecutiveFailures); cancelled=\(Task.isCancelled); routine successes sampled=\(sampled)")
            }
            lastSent = now
            status = response.status == 200 ? "Sharing GPS with comma"
                : response.status == 405 ? "This comma doesn't take phone GPS yet." : "Comma didn't accept the location."
        } catch {
            failed += 1; consecutiveFailures += 1
            if let onEvent {
                let completedUptime = diagnosticClock()
                let sampled = successDiagnostics.take(routineSuccess: false, now: completedUptime) ?? 0
                onEvent("Upload #\(uploadID) failed: \((error as NSError).domain) \((error as NSError).code); elapsed=\(completedUptime - startedUptime)s; cancelled=\(Task.isCancelled); consecutive failures=\(consecutiveFailures); routine successes sampled=\(sampled)")
            }
            status = "Waiting for comma"
        }
    }

    /// iOS marks an unknown value with a negative number; those are left out.
    nonisolated static func payload(_ location: CLLocation, now: Date) -> Data? {
        let age = now.timeIntervalSince(location.timestamp) * 1000
        guard age >= 0, age <= maxAgeMs, location.horizontalAccuracy > 0, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        var value: [String: Any] = ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                                    "horizontalAccuracy": location.horizontalAccuracy, "ageMs": Int(age.rounded()),
                                    "timestamp": Int64(location.timestamp.timeIntervalSince1970 * 1000)]
        if location.verticalAccuracy > 0 { value["altitude"] = location.altitude; value["verticalAccuracy"] = location.verticalAccuracy }
        if location.speed >= 0 { value["speed"] = location.speed }
        if location.speedAccuracy >= 0 { value["speedAccuracy"] = location.speedAccuracy }
        if location.course >= 0, location.courseAccuracy >= 0 { value["bearing"] = location.course; value["bearingAccuracy"] = location.courseAccuracy }
        return try? JSONSerialization.data(withJSONObject: value)
    }
}
