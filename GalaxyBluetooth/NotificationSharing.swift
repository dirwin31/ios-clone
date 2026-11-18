import Foundation
import UserNotifications

enum NotificationBondError: Error, Equatable {
    case unavailable, declined, timedOut, disconnected, staleBond, busy, failed
}

/// iOS shares notifications only with a bonded accessory, so comma reads them itself over Apple's notification service.
/// The app opens comma's short bond window, then reads an encrypted characteristic so iOS shows its pairing request.
@MainActor
final class NotificationSharing: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requesting
        case waitingForMusic
        case relinking
        case pairing
        case done
        case message(String)
    }

    static let windowPath = "/_bridge/notification-bond"
    static let hintKey = "galaxy.notifications.sharedDevice"
    static let updateMessage = "Update StarPilot on your comma to use phone notifications."
    static let bluetoothMessage = "Connect to comma over Bluetooth to set this up."

    static let testTitle = "StarPilot test notification"
    static let testType = "starpilotTest"

    var onEvent: ((String) -> Void)?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var testStatus: String?
    private let transport: () -> (any GalaxyRequestTransport)?
    private let supported: () -> Bool
    private let bond: () async throws -> Void
    private let device: () -> String?
    private let musicDone: () -> Bool
    private let closeMusicWindow: () async -> Void
    private let pause: () async -> Void
    private let relink: () async -> Void
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    /// `transport` must be the Bluetooth transport: the bond belongs to that link.
    init(transport: @escaping () -> (any GalaxyRequestTransport)?, supported: @escaping () -> Bool,
         bond: @escaping () async throws -> Void, device: @escaping () -> String?, defaults: UserDefaults = .standard,
         musicDone: @escaping () -> Bool = { false }, closeMusicWindow: @escaping () async -> Void = {},
         pause: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 2_000_000_000) },
         relink: @escaping () async -> Void = {}) {
        self.transport = transport; self.supported = supported; self.bond = bond; self.device = device; self.defaults = defaults
        self.musicDone = musicDone; self.closeMusicWindow = closeMusicWindow; self.pause = pause; self.relink = relink
    }

    /// Comma's music window lasts two minutes and blocks the notification bond; wait for it instead of failing.
    static let musicWindowWaits = 70

    var active: Bool { phase == .requesting || phase == .waitingForMusic || phase == .relinking || phase == .pairing }

    /// A hint only: the person can turn sharing off in iPhone Settings without the app knowing.
    var sharedWithThisComma: Bool {
        guard let id = device(), !id.isEmpty else { return false }
        return defaults.string(forKey: Self.hintKey) == id
    }

    func summary(bluetoothConnected: Bool) -> String {
        switch phase {
        case .requesting, .waitingForMusic, .relinking, .pairing: return "Setup in progress"
        case .done: return "On · shared with comma"
        case .message: return "Setup needs attention"
        case .idle:
            if bluetoothConnected && !supported() { return "Needs a StarPilot update on comma" }
            return sharedWithThisComma ? "On · shared with comma" : "Not set up"
        }
    }

    func start() {
        guard task == nil else { return }
        onEvent?("Phone notifications setup started")
        phase = .requesting
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismiss() { if active { cancel() } else { phase = .idle } }

    /// Posts a local notification; iOS shares it with comma like any other, so it checks the whole path.
    func sendTest() async {
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        var justAllowed = false
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: allowed = true
        case .notDetermined:
            allowed = (try? await center.requestAuthorization(options: [.alert])) ?? false
            justAllowed = allowed
        default: allowed = false
        }
        guard allowed else {
            testStatus = "Allow notifications for this app in iPhone **Settings → Notifications** so it can send a test."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = Self.testTitle
        content.body = "If sharing works, this shows on your comma and car screen."
        content.userInfo = ["type": Self.testType]
        let request = UNNotificationRequest(identifier: "starpilot-test-" + UUID().uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: justAllowed ? 3 : 1, repeats: false))
        // Right after the permission alert iOS can still be settling the new permission, and the first test was
        // lost. Give it a moment so the test works on the first tap.
        if justAllowed { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        do {
            try await center.add(request)
            onEvent?("Phone notifications test posted")
            testStatus = "Test sent. It should show on the comma or car screen in a few seconds.\nNothing? In **Settings → Bluetooth**, tap ⓘ next to comma and turn on **Share System Notifications**."
        } catch {
            testStatus = "Couldn't send the test. Try again."
        }
    }

    private func run() async {
        guard let first = transport(), first.connected else { phase = .message(Self.bluetoothMessage); return }
        guard supported() else { phase = .message(Self.updateMessage); return }
        var relinked = false
        while true {
            guard let transport = transport(), transport.connected else {
                phase = .message(relinked ? Self.relinkMessage : Self.bluetoothMessage); return
            }
            guard let seconds = await openWindow(transport) else { return }
            // 0 means comma already knows this link as the paired iPhone (the pairing made with Phone music).
            if seconds == 0 || relinked { break }
            // Pairing music in iPhone Settings gives comma the keys for this iPhone, but a Bluetooth link opened before
            // that pairing keeps its old unknown identity. A fresh link is recognised as the paired iPhone.
            relinked = true
            phase = .relinking
            onEvent?("Phone notifications refreshing the Bluetooth link")
            await relink()
            if Task.isCancelled { return }
            phase = .requesting
        }
        phase = .pairing
        do {
            try await bond()
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            onEvent?("Phone notifications pairing failed: \(error)")
            phase = .message(Self.message(for: error))
            return
        }
        if Task.isCancelled { return }
        if let id = device(), !id.isEmpty { defaults.set(id, forKey: Self.hintKey) }
        onEvent?("Phone notifications pairing finished")
        phase = .done
    }

    /// Asks comma for its notification bond window; returns its seconds (0 when already paired), or nil after setting a message.
    private func openWindow(_ transport: any GalaxyRequestTransport) async -> Int? {
        var response: BridgeResponse
        var waits = 0
        while true {
            do {
                response = try await transport.request(path: Self.windowPath, method: "POST",
                                                       headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
            } catch {
                if Task.isCancelled { return nil }
                onEvent?("Phone notifications window request failed: " + error.localizedDescription)
                phase = .message(transport.connected ? Self.updateMessage : Self.bluetoothMessage)
                return nil
            }
            if Task.isCancelled { return nil }
            onEvent?("Phone notifications window request finished: HTTP \(response.status)")
            guard response.status == 409, Self.code(response.bodyData) == "pairing_window" else { break }
            guard waits < Self.musicWindowWaits else { phase = .message(Self.musicWindowMessage); return nil }
            // Nobody is setting up music (finished, cancelled, or the window is just left open from pairing the app): close it so setup continues at once.
            if waits == 0 { phase = .waitingForMusic; onEvent?("Phone notifications: comma's pairing window is open; music setup running=\(!musicDone())") }
            if musicDone() {
                onEvent?("Phone notifications closing comma's leftover pairing window (attempt \(waits + 1))")
                await closeMusicWindow()
            } else if waits % 5 == 0 { onEvent?("Phone notifications waiting for the music pairing window") }
            waits += 1
            await pause()
            if Task.isCancelled { return nil }
        }
        switch response.status {
        case 200:
            let value = (try? JSONSerialization.jsonObject(with: response.bodyData)) as? [String: Any]
            return (value?["seconds"] as? Int) ?? 60
        case 409:
            phase = .message(Self.busyMessage(response.bodyData)); return nil
        case 400, 404, 405, 501:
            phase = .message(Self.updateMessage); return nil
        default:
            phase = .message("Comma couldn't start setup. Try again."); return nil
        }
    }

    nonisolated static let needsMusicMessage = "Your iPhone didn't pair with comma for notifications. Set up **Phone music** first and tap **Pair** when iOS asks: notifications use the same pairing."
    nonisolated static let relinkMessage = "Comma didn't reconnect in time. Tap **Try again**; setup picks up where it left off."
    nonisolated static let musicWindowMessage = "Comma is still finishing music pairing. Try again in a minute."

    nonisolated static func code(_ body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["code"] as? String
    }

    /// Map comma's reason code to app copy; its own text is never shown.
    nonisolated static func busyMessage(_ body: Data) -> String {
        switch code(body) {
        case "pairing_window"?: return musicWindowMessage
        case "park_required"?: return "Park the car to set up phone notifications."
        case "bluetooth_off"?, "bluetooth_unavailable"?, "starting"?, "not_ready"?: return "Comma's Bluetooth isn't ready. Try again in a moment."
        case "disconnected"?: return message(for: NotificationBondError.disconnected)
        default: return "Comma is busy pairing another device. Wait a minute, then try again."
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error as? NotificationBondError {
        case .declined?: return needsMusicMessage
        case .timedOut?: return "iOS didn't finish pairing in time. Try again and tap **Pair** when iOS asks."
        case .disconnected?: return "Comma disconnected during setup. Reconnect over Bluetooth and try again."
        case .unavailable?: return "Your iPhone hasn't seen comma's new Bluetooth features yet. Turn Bluetooth off and on, reconnect, then try again."
        case .staleBond?: return "Your iPhone's saved pairing with comma has changed. In **Settings → Bluetooth**, tap ⓘ next to comma, choose **Forget This Device**, then reconnect and try again."
        case .busy?: return "Setup is already running."
        case .failed?, nil: return "Pairing didn't finish. Try again."
        }
    }
}
