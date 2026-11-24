import SwiftUI
import UserNotifications
import CryptoKit

@MainActor
final class SentryPush: ObservableObject {
    static let shared = SentryPush()
    @Published private(set) var enabled: Bool
    @Published private(set) var registered = false
    @Published private(set) var status = "Phone alerts off"
    @Published var openEvents = false
    @Published private(set) var testingPhoto = false
    private var token = ""
    private var busy = false
    private var registeredDevice = ""
    private var permissionRequest = UUID()
    private var lastAttempt = Date.distantPast
    var transport: (any GalaxyRequestTransport)?
    private let defaults: UserDefaults
    private let environment: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         environment: String = Bundle.main.object(forInfoDictionaryKey: "SentryAPNsEnvironment") as? String ?? "",
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.environment = environment
        self.now = now
        enabled = defaults.bool(forKey: "galaxy.sentry.enabled")
        if enabled { status = "Waiting for registration" }
    }
    private var identity: String { defaults.string(forKey: "galaxy.comma.identity") ?? "" }
    private var subscribed: [String: String] {
        get { defaults.dictionary(forKey: "galaxy.sentry.subscriptions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "galaxy.sentry.subscriptions") }
    }
    var id: String { token.isEmpty ? "" : SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description }
    var stateJSON: String {
        let value: [String: Any] = ["available": true, "enabled": enabled, "registered": registered, "id": id, "status": status]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    func restore() {
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    func setEnabled(_ on: Bool) async {
        let requestID = UUID()
        permissionRequest = requestID
        if on {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                    status = "Allow notifications in iPhone Settings to receive Sentry alerts."
                    return
                }
            } catch { status = "Couldn’t request notification permission."; return }
            guard permissionRequest == requestID else { return }
            enabled = true
            defaults.set(true, forKey: "galaxy.sentry.enabled")
            defaults.set(true, forKey: "galaxy.sentry.enrollRequested")
            status = "Registering this iPhone…"
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            enabled = false
            defaults.set(false, forKey: "galaxy.sentry.enabled")
            defaults.set(false, forKey: "galaxy.sentry.enrollRequested")
            registered = false
            UIApplication.shared.unregisterForRemoteNotifications()
            status = "Phone alerts disabled. Reconnect to comma to remove its subscription."
        }
        lastAttempt = .distantPast
        await synchronize()
    }

    func receivedToken(_ data: Data) {
        guard ["production", "development"].contains(environment) else { status = "This build has no APNs environment configured."; return }
        token = "apns.\(environment == "development" ? "sandbox" : "production")." + data.map { String(format: "%02x", $0) }.joined()
        registered = false
        lastAttempt = .distantPast
        Task { await synchronize() }
    }

    func registrationFailed() { registered = false; status = "Apple push registration failed. Check internet access and the app’s Push Notifications capability." }

    private func request(_ body: [String: Any], over transport: any GalaxyRequestTransport) async throws -> [String: Any] {
        let result = try await transport.request(path: "/api/sentry/notifications", method: "POST",
            headers: ["Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        guard result.status == 200, let value = try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any] else {
            throw BridgeError.message("Couldn’t update phone alerts on comma (HTTP \(result.status)).")
        }
        return value
    }

    func synchronize() async {
        if registeredDevice != identity { registered = false }
        guard !busy, let transport, transport.connected, !identity.isEmpty,
              now().timeIntervalSince(lastAttempt) >= 60 else { return }
        let device = identity
        guard enabled ? !token.isEmpty : subscribed[device] != nil else { return }
        busy = true
        lastAttempt = now()
        defer { busy = false }
        do {
            let currentToken = token
            if let old = subscribed[device], !enabled || old != currentToken {
                _ = try await request(["action": "appUnsubscribe", "token": old], over: transport)
                var values = subscribed; values.removeValue(forKey: device); subscribed = values
            }
            guard enabled else { status = "Phone alerts disabled."; return }
            guard device == identity else { return }
            var result = try await request(["action": "appSubscribe", "token": currentToken,
                "appId": Bundle.main.bundleIdentifier ?? "", "label": "iPhone"], over: transport)
            var values = subscribed; values[device] = currentToken; subscribed = values
            guard device == identity else { lastAttempt = .distantPast; return }
            if !enabled {
                _ = try await request(["action": "appUnsubscribe", "token": currentToken], over: transport)
                values.removeValue(forKey: device); subscribed = values
                status = "Phone alerts disabled."
                return
            }
            guard device == identity, token == currentToken else { lastAttempt = .distantPast; return }
            if defaults.bool(forKey: "galaxy.sentry.enrollRequested") {
                if let relay = result["relayEnrollment"] as? [String: Any] {
                    let state = relay["state"] as? String ?? ""
                    // Only start a new enrollment from a state the comma allows.
                    // Recovery/revocation needs an explicit action in Galaxy.
                    if ["unenrolled", "revoked"].contains(state), relay["automaticConfigured"] as? Bool == true {
                        result = try await request(["action": "relayEnroll", "confirmed": true], over: transport)
                        defaults.set(false, forKey: "galaxy.sentry.enrollRequested")
                    } else if ["enrolling", "enrolled", "rotating", "confirming", "revoking", "actionRequired"].contains(state) {
                        defaults.set(false, forKey: "galaxy.sentry.enrollRequested")
                    }
                } else { defaults.set(false, forKey: "galaxy.sentry.enrollRequested") }
            }
            guard enabled, device == identity, token == currentToken else { lastAttempt = .distantPast; return }
            registered = true
            registeredDevice = device
            let enrollment = (result["relayEnrollment"] as? [String: Any])?["state"] as? String
            switch enrollment {
            case "enrolling", "rotating", "confirming": status = "Phone registered. Waiting for relay enrollment in Galaxy → Sentry."
            case "unenrolled", "revoked": status = (result["relayEnrollment"] as? [String: Any])?["automaticConfigured"] as? Bool == true ? "Enable alerts to enroll this comma automatically." : "Phone registered. Hosted alerts are not configured in this release yet."
            case "revoking": status = "Relay revocation pending. Push alerts are paused."
            case "actionRequired": status = "Relay authorization needs attention in Galaxy → Sentry."
            default: status = result["appPushAvailable"] as? Bool == true ? "Registered. Park the car to send a photo test." : "Registered. Configure the HTTPS push relay in Galaxy → Sentry."
            }
        } catch { registered = false; status = "Couldn’t register phone alerts. Reconnect and check Galaxy’s relay settings." }
    }

    func testPhoto(camera: String, tunnelReady: Bool, over route: any GalaxyRequestTransport) async {
        guard !testingPhoto, enabled, registered, registeredDevice == identity else { return }
        guard tunnelReady else {
            status = "Sign in to Galaxy Tunnel and use Automatic to test photo alerts."
            return
        }
        guard route.connected else {
            status = "Connect over Local Wi-Fi or Galaxy Tunnel to take a test photo."
            return
        }

        testingPhoto = true
        defer { testingPhoto = false }
        let cameraName = camera == "cabin" ? "Cabin" : "Road"
        let device = identity
        status = "Taking a \(cameraName) camera photo…"
        do {
            let body = try JSONSerialization.data(withJSONObject: ["id": id, "camera": camera])
            let response = try await route.request(path: "/api/sentry/notifications/photo-test", method: "POST",
                headers: ["Content-Type": "application/json"], body: body)
            guard device == identity, enabled else { return }
            switch response.status {
            case 200:
                let reply = try JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any]
                status = reply?["queued"] as? Bool == true
                    ? "Photo test queued. Press and hold the notification to see the image."
                    : "Couldn’t confirm the photo test. Check for a notification."
            case 404:
                status = "Photo test unavailable. Update Galaxy or reconnect to register this iPhone again."
            case 409:
                status = "Park the car before sending a photo test."
            default:
                let reply = try? JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any]
                status = reply?["error"] as? String ?? "Couldn’t send the photo test (HTTP \(response.status))."
            }
        } catch {
            guard device == identity, enabled else { return }
            status = "Couldn’t confirm the photo test. Check for a notification, then try again if needed."
        }
    }
}

@MainActor
final class SentryAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SentryPush.shared.restore()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { SentryPush.shared.receivedToken(token) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { SentryPush.shared.registrationFailed() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completion(SentryPush.shared.enabled ? [.banner, .sound, .list] : []) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completion: @escaping () -> Void) {
        guard response.notification.request.content.userInfo["type"] as? String == "sentry" else { completion(); return }
        Task { @MainActor in
            SentryPush.shared.openEvents = true
            AppModel.shared.tab = .galaxy
            completion()
        }
    }
}
