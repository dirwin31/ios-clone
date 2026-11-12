import SwiftUI
import AppIntents
import Combine
import UserNotifications

/// Shared places go to comma, which starts the route; when comma cannot pick one place, Galaxy's navigation page searches the text.
@MainActor
final class ShareInbox: ObservableObject {
    static let shared = ShareInbox()
    static let saved = "Saved. The route starts when your iPhone next connects to comma."
    /// Text waiting for the Galaxy page to load it.
    @Published var galaxyText: String?
    @Published var notice: String?
    /// The Galaxy page is being sent the text; it is cleared once that succeeds.
    var sending = false
    private var delivering = false
    private var observers: [AnyCancellable] = []
    private weak var model: AppModel?

    func receive(_ url: URL, model: AppModel) {
        guard let text = SharedDestination.text(from: url) else { return }
        model.connectionLog.record("Shared destination received")
        let identity = UserDefaults.standard.string(forKey: "galaxy.comma.identity")
        let requestID = ShareGroup.replacePreviousShare()
        Task {
            switch await CommaDestination.send(text: text, model: model, requestID: requestID, identity: identity) {
            case .started(let name):
                notice = "Route to \(name) started on comma."
                if model.navigationEnabled { model.tab = .navigation }
            case .refused(let reason): notice = reason
            case .needsSearch(let resolved): show(resolved, model: model)
            case .unreachable:
                notice = ShareGroup.queue(DestinationSender.capped(text), identity: identity, requestID: requestID)
                    ? Self.saved : "Connect to your comma, then share this place again."
            }
        }
    }

    func show(_ text: String, model: AppModel) {
        galaxyText = text
        model.tab = model.opened ? .galaxy : .connections
    }

    /// Delivers places the share extension or Siri saved while comma was out of reach.
    func attach(_ model: AppModel) {
        self.model = model
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in ShareInbox.shared.deliverPending() }
        }, ShareGroup.pendingNotification as CFString, nil, .deliverImmediately)
        observers = [model.bluetooth.$connected, model.lan.$connected, model.tunnel.$connected].map {
            $0.removeDuplicates().filter { $0 }.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.deliverPending() }
        }
        observers.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .sink { [weak self] _ in self?.mirror() })
        mirror()
        mirrorTunnel()
        deliverPending()
    }

    func activated(model: AppModel) {
        if let text = ShareGroup.takeSearch() { show(text, model: model) }
        deliverPending()
    }

    /// The extension reads only these copies; the app's own storage is unchanged.
    func mirror() {
        let defaults = UserDefaults.standard
        ShareGroup.mirror(.init(address: defaults.string(forKey: "galaxy.lan.address"), identity: defaults.string(forKey: "galaxy.comma.identity"),
                                mode: defaults.string(forKey: "galaxy.connection.mode")))
    }
    func mirrorTunnel() { ShareGroup.mirror(tunnel: TunnelKeyStore.load().map { .init(url: $0.url, cookie: $0.cookie) }) }

    func deliverPending() {
        guard let model, !delivering, let pending = ShareGroup.pending() else { return }
        guard ShareGroup.isCurrent(pending.id), pending.belongs(to: UserDefaults.standard.string(forKey: "galaxy.comma.identity")) else { return }
        delivering = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Shared destination")
        Task {
            defer {
                delivering = false
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            model.connectionLog.record("Saved shared destination: sending to comma")
            let outcome = await CommaDestination.send(text: pending.text, model: model, requestID: pending.id, identity: pending.identity)
            guard ShareGroup.isCurrent(pending.id) else { return }
            if case .unreachable = outcome { return }
            ShareGroup.clear(pending.id)
            let active = UIApplication.shared.applicationState == .active
            let message: String
            switch outcome {
            case .started(let name): message = "Route to \(name) started on comma."
            case .refused(let reason): message = reason
            case .needsSearch(let text):
                if active { show(text, model: model); return }
                ShareGroup.stashSearch(text)
                message = "comma couldn’t find one place for this. Open StarPilot BT to choose it."
            case .unreachable: return
            }
            if active { notice = message } else { await Self.notify(message) }
            if ShareGroup.pending() != nil { Task { self.deliverPending() } }
        }
    }

    /// Uses notification permission the app already has; never asks for it.
    private static func notify(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        guard [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.body = message
        try? await center.add(UNNotificationRequest(identifier: "shared-destination", content: content, trigger: nil))
    }

    /// Galaxy reloads into its navigation page with the shared text, which it opens or searches.
    func script() -> String? {
        guard !sending, let text = galaxyText, let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return nil }
        return "location.assign(location.pathname + '?share=' + encodeURIComponent(\(literal)) + '#/navigation')"
    }
}

/// Sends shared text to comma over whatever reaches it: the app's current connection, the saved home network, then the tunnel.
@MainActor
enum CommaDestination {
    static func send(text: String, model: AppModel, requestID: String, identity: String?) async -> DestinationSender.Outcome {
        // Short links are opened on the phone; comma may have no route to Google.
        let resolved = await SharedDestination.resolve(DestinationSender.capped(text)) { await RedirectProbe().location(of: $0) }
        var result = DestinationSender.Outcome.unreachable("comma is not reachable")
        for route in [current, lan, tunnel] {
            guard let transport = await route(model) else { continue }
            guard identity == UserDefaults.standard.string(forKey: "galaxy.comma.identity") else {
                return .refused("Selected comma changed. Share the destination again.")
            }
            result = await DestinationSender.share(text: resolved, status: {
                let reply = try await transport.request(path: "/api/navigation/status", method: "GET", headers: [:], body: Data())
                return (reply.status, reply.bodyData)
            }, action: { payload in
                guard ShareGroup.isCurrent(requestID) else { throw DestinationSender.Failure.refused("A newer shared destination replaced this one.") }
                guard identity == UserDefaults.standard.string(forKey: "galaxy.comma.identity") else {
                    throw DestinationSender.Failure.refused("Selected comma changed. Share the destination again.")
                }
                let reply = try await transport.request(path: "/api/navigation/action", method: "POST", headers: ["content-type": "application/json"],
                                                        body: try JSONSerialization.data(withJSONObject: payload))
                return (reply.status, reply.bodyData)
            })
            if case .unreachable = result { continue }
            model.connectionLog.record("Shared destination answered by comma")
            return result
        }
        model.connectionLog.record("Shared destination: comma not reachable")
        return result
    }

    private static func current(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        model.transport.connected ? model.transport : nil
    }
    private static func lan(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        guard model.mode != .bluetooth else { return nil }
        if !model.lan.connected {
            let address = UserDefaults.standard.string(forKey: "galaxy.lan.address") ?? ""
            if !address.isEmpty { try? model.lan.configure(address: address) }
            guard await model.lan.probe() else { return nil }
        }
        return model.lan
    }
    private static func tunnel(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        guard model.mode == .automatic, model.tunnel.credential != nil else { return nil }
        if !model.tunnel.connected { guard await model.tunnel.probe() else { return nil } }
        return model.tunnel
    }
}

/// Siri and Shortcuts action: comma starts the route to a shared place; when comma is out of reach the place is saved for later.
struct SendToStarPilotIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Send to StarPilot"
    static let description = IntentDescription("Starts a route on your comma using a shared map link.")
    static let openAppWhenRun = false
    @Parameter(title: "Place", description: "A shared Google Maps, Apple Maps or Waze place or link") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let shared = DestinationSender.capped(text)
        let identity = UserDefaults.standard.string(forKey: "galaxy.comma.identity")
        let requestID = ShareGroup.replacePreviousShare()
        switch await CommaDestination.send(text: shared, model: model, requestID: requestID, identity: identity) {
        case .started(let name): return .result(dialog: "Route to \(name) started on comma.")
        case .refused(let reason): return .result(dialog: "\(reason)")
        case .needsSearch(let resolved):
            throw needsToContinueInForegroundError("comma couldn’t find one place for this. Open StarPilot to search for it?") {
                ShareInbox.shared.show(resolved, model: model)
            }
        case .unreachable:
            let saved = ShareGroup.queue(shared, identity: identity, requestID: requestID)
            return .result(dialog: "\(saved ? ShareInbox.saved : "Connect to your comma, then share this place again.")")
        }
    }
}

struct ShareNotice: ViewModifier {
    @ObservedObject var inbox = ShareInbox.shared
    func body(content: Content) -> some View {
        content.alert(inbox.notice ?? "", isPresented: Binding(get: { inbox.notice != nil }, set: { if !$0 { inbox.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
