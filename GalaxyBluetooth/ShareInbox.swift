import SwiftUI
import AppIntents

/// Shared places go straight to comma when they carry coordinates; otherwise Galaxy's navigation page receives the text.
@MainActor
final class ShareInbox: ObservableObject {
    static let shared = ShareInbox()
    /// Text waiting for the Galaxy page to load it.
    @Published var galaxyText: String?
    @Published var notice: String?
    /// The Galaxy page is being sent the text; it is cleared once that succeeds.
    var sending = false
    private let probe = RedirectProbe()

    func receive(_ url: URL, model: AppModel) {
        guard let text = SharedDestination.text(from: url) else { return }
        model.connectionLog.record("Shared destination received")
        Task {
            // Short links are opened on the phone so any comma's Galaxy can read the coordinates.
            let resolved = await SharedDestination.resolve(text) { [probe] in await probe.location(of: $0) }
            if case let .place(name, latitude, longitude) = SharedDestination.parse(resolved) {
                if await CommaDestination.send(name: name, latitude: latitude, longitude: longitude, model: model) == nil {
                    notice = "Route to \(name) started on comma."
                    if model.navigationEnabled { model.tab = .navigation }
                    return
                }
                model.connectionLog.record("Shared destination not sent directly; opening Galaxy")
            }
            show(resolved, model: model)
        }
    }

    func show(_ text: String, model: AppModel) {
        galaxyText = text
        model.tab = model.opened ? .galaxy : .connections
    }

    /// Galaxy reloads into its navigation page with the shared text, which it opens or searches.
    func script() -> String? {
        guard !sending, let text = galaxyText, let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return nil }
        return "location.assign(location.pathname + '?share=' + encodeURIComponent(\(literal)) + '#/navigation')"
    }
}

/// Sends a place to comma over whatever reaches it: the app's current connection, the saved home network, then the tunnel.
@MainActor
enum CommaDestination {
    /// Returns nil once comma is routing to the place, else why it could not be sent.
    static func send(name: String, latitude: Double, longitude: Double, model: AppModel) async -> String? {
        var reason = "comma is not reachable"
        for route in [current, lan, tunnel] {
            guard let transport = await route(model) else { continue }
            do {
                try await DestinationSender.start(name: name, latitude: latitude, longitude: longitude, status: {
                    let reply = try await transport.request(path: "/api/navigation/status", method: "GET", headers: [:], body: Data())
                    return (reply.status, reply.bodyData)
                }, action: { payload in
                    let reply = try await transport.request(path: "/api/navigation/action", method: "POST", headers: ["content-type": "application/json"],
                                                            body: try JSONSerialization.data(withJSONObject: payload))
                    return (reply.status, reply.bodyData)
                })
                model.connectionLog.record("Shared destination sent to comma")
                return nil
            } catch DestinationSender.Failure.refused(let message) {
                return message
            } catch DestinationSender.Failure.unreachable(let message) {
                reason = message
            } catch {}
        }
        return reason
    }

    private static func current(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        model.transport.connected ? model.transport : nil
    }
    private static func lan(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        if !model.lan.connected {
            let address = UserDefaults.standard.string(forKey: "galaxy.lan.address") ?? ""
            if !address.isEmpty { try? model.lan.configure(address: address) }
            guard await model.lan.probe() else { return nil }
        }
        return model.lan
    }
    private static func tunnel(_ model: AppModel) async -> (any GalaxyRequestTransport)? {
        guard model.tunnel.credential != nil else { return nil }
        if !model.tunnel.connected { guard await model.tunnel.probe() else { return nil } }
        return model.tunnel
    }
}

/// Shortcuts action: share a place from Google or Apple Maps and comma starts the route, without opening the app.
struct SendToStarPilotIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Send to StarPilot"
    static let description = IntentDescription("Sets comma's destination to a place shared from Google or Apple Maps and starts the route.")
    static let openAppWhenRun = false
    @Parameter(title: "Place", description: "A shared Google or Apple Maps place or link") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let shared = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SharedDestination.maxText))
        let resolved = await SharedDestination.resolve(shared) { await RedirectProbe().location(of: $0) }
        guard case let .place(name, latitude, longitude) = SharedDestination.parse(resolved) else {
            throw needsToContinueInForegroundError("This place has no map location. Open StarPilot to search for it?") {
                ShareInbox.shared.show(resolved, model: model)
            }
        }
        if let reason = await CommaDestination.send(name: name, latitude: latitude, longitude: longitude, model: model) {
            throw needsToContinueInForegroundError("\(reason). Open StarPilot to send it?") { ShareInbox.shared.show(resolved, model: model) }
        }
        return .result(dialog: "Route to \(name) started on comma.")
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
