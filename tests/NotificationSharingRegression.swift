import Foundation

struct BridgeResponse { let status: Int; let bodyData: Data }
enum Wire { static let maxBody = 1_048_576 }
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor final class BondComma: GalaxyRequestTransport {
    var connected = true
    var status = 200
    var reply = #"{"ok":true,"seconds":0}"#
    var failure: Error?
    var dropOnRequest = false
    var posts = 0
    var windowPosts = 0
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        precondition(path == "/_bridge/notification-bond" && method == "POST" && body == Data("{}".utf8))
        posts += 1
        if dropOnRequest { connected = false }
        if let failure { throw failure }
        if posts <= windowPosts { return BridgeResponse(status: 409, bodyData: Data(#"{"error":"x","code":"pairing_window"}"#.utf8)) }
        return BridgeResponse(status: status, bodyData: Data(reply.utf8))
    }
}

@main struct NotificationSharingRegression {
    @MainActor static func settle(_ model: NotificationSharing, until done: (NotificationSharing.Phase) -> Bool) async {
        for _ in 0..<2000 {
            if done(model.phase) { return }
            await Task.yield()
        }
        preconditionFailure("Notification sharing never reached the expected phase: \(model.phase)")
    }

    @MainActor static func run(_ comma: BondComma?, supported: Bool = true, bond: Error? = nil,
                               defaults: UserDefaults) async -> (NotificationSharing, Int) {
        var reads = 0
        let model = NotificationSharing(transport: { comma }, supported: { supported },
                                        bond: { reads += 1; if let bond { throw bond } },
                                        device: { "comma-1" }, defaults: defaults)
        model.start()
        await settle(model) { $0 != .requesting && $0 != .pairing && $0 != .waitingForMusic && $0 != .relinking }
        return (model, reads)
    }

    @MainActor static func main() async {
        let defaults = UserDefaults(suiteName: "notification-sharing-\(UUID().uuidString)")!

        // Not on Bluetooth: nothing is sent and no pairing is attempted.
        let offline = BondComma(); offline.connected = false
        var (model, reads) = await run(offline, defaults: defaults)
        precondition(model.phase == .message(NotificationSharing.bluetoothMessage) && offline.posts == 0 && reads == 0)
        (model, reads) = await run(nil, defaults: defaults)
        precondition(model.phase == .message(NotificationSharing.bluetoothMessage) && reads == 0)

        // Comma health says it predates the feature.
        let unsupported = BondComma()
        (model, reads) = await run(unsupported, supported: false, defaults: defaults)
        precondition(model.phase == .message(NotificationSharing.updateMessage) && unsupported.posts == 0)
        precondition(model.summary(bluetoothConnected: true) == "Setup needs attention")
        model.dismiss()
        precondition(model.summary(bluetoothConnected: true) == "Needs a StarPilot update on comma")

        // Comma busy with another pairing.
        let busy = BondComma(); busy.status = 409
        (model, reads) = await run(busy, defaults: defaults)
        guard case .message(let text) = model.phase else { preconditionFailure() }
        precondition(text.contains("busy") && reads == 0)
        let parked = BondComma(); parked.status = 409
        parked.reply = #"{"error":"Park the car or turn it off to pair a phone.","code":"park_required"}"#
        (model, reads) = await run(parked, defaults: defaults)
        precondition(model.phase == .message("Park the car to set up phone notifications.") && reads == 0)
        let radio = BondComma(); radio.status = 409; radio.reply = #"{"error":"x","code":"starting"}"#
        (model, reads) = await run(radio, defaults: defaults)
        precondition(model.phase == .message("Comma's Bluetooth isn't ready. Try again in a moment."))
        let unknown = BondComma(); unknown.status = 409; unknown.reply = #"{"error":"Raw server sentence","code":"something_new"}"#
        (model, reads) = await run(unknown, defaults: defaults)
        guard case .message(let fallback) = model.phase else { preconditionFailure() }
        precondition(fallback == text && !fallback.contains("Raw server") && reads == 0, "Unknown codes use the busy sentence, never server text")

        // Older comma: unknown route or a bridge error while still connected.
        for status in [400, 404] {
            let old = BondComma(); old.status = status
            (model, reads) = await run(old, defaults: defaults)
            precondition(model.phase == .message(NotificationSharing.updateMessage) && reads == 0)
        }
        let erroring = BondComma(); erroring.failure = BridgeError.message("Unknown bridge path")
        (model, reads) = await run(erroring, defaults: defaults)
        precondition(model.phase == .message(NotificationSharing.updateMessage) && reads == 0)
        let dropped = BondComma(); dropped.failure = BridgeError.message("Bluetooth connection closed."); dropped.dropOnRequest = true
        (model, reads) = await run(dropped, defaults: defaults)
        precondition(model.phase == .message(NotificationSharing.bluetoothMessage))

        // Pairing declined, timed out or interrupted: a plain message, no saved hint.
        for (error, word) in [(NotificationBondError.declined, "Pair"), (.timedOut, "in time"), (.disconnected, "disconnected"), (.staleBond, "Forget")] {
            (model, reads) = await run(BondComma(), bond: error, defaults: defaults)
            guard case .message(let text) = model.phase else { preconditionFailure() }
            precondition(text.contains(word) && reads == 1, "\(error) → \(text)")
        }
        precondition(!model.sharedWithThisComma)
        precondition(model.summary(bluetoothConnected: true) == "Setup needs attention")
        model.dismiss()
        precondition(model.summary(bluetoothConnected: true) == "Not set up")

        // Success: bonded, hint saved for this comma, and setup can run again.
        let good = BondComma()
        (model, reads) = await run(good, defaults: defaults)
        precondition(model.phase == .done && reads == 1 && good.posts == 1)
        precondition(defaults.string(forKey: NotificationSharing.hintKey) == "comma-1")
        model.dismiss()
        precondition(model.phase == .idle && model.summary(bluetoothConnected: true) == "Set up on this comma")
        model.start()
        await settle(model) { $0 == .done }
        precondition(good.posts == 2)

        // A different comma does not inherit the hint.
        let other = NotificationSharing(transport: { good }, supported: { true }, bond: {}, device: { "comma-2" }, defaults: defaults)
        precondition(!other.sharedWithThisComma && other.summary(bluetoothConnected: true) == "Not set up")

        // Closing the sheet while iOS is asking cancels the wait without an error message.
        let slow = NotificationSharing(transport: { good }, supported: { true },
                                       bond: { try await Task.sleep(nanoseconds: 10_000_000_000) }, device: { "comma-3" }, defaults: defaults)
        slow.start()
        await settle(slow) { $0 == .pairing }
        slow.dismiss()
        for _ in 0..<50 { await Task.yield() }
        precondition(slow.phase == .idle && !slow.sharedWithThisComma)

        // The Bluetooth link is refreshed before asking comma, so a pairing made in iPhone Settings applies to it.
        var relinks = 0
        let stale = BondComma(); stale.reply = #"{"ok":true,"seconds":60}"#
        let relinked = NotificationSharing(transport: { stale }, supported: { true }, bond: {}, device: { "comma-6" }, defaults: defaults,
                                           relink: { relinks += 1; stale.reply = #"{"ok":true,"seconds":0}"# })
        relinked.start()
        await settle(relinked) { $0 == .done }
        precondition(relinks == 1 && stale.posts == 2, "Refreshes an unrecognised link once, then asks again")
        var quiet = 0
        let known = NotificationSharing(transport: { good }, supported: { true }, bond: {}, device: { "comma-7" }, defaults: defaults,
                                        relink: { quiet += 1 })
        known.start()
        await settle(known) { $0 == .done }
        precondition(quiet == 0, "A link comma already knows is not dropped")
        precondition(NotificationSharing.message(for: NotificationBondError.declined) == NotificationSharing.needsMusicMessage)

        // Music's pairing window is still open: wait for it (closing it once music is done) instead of failing.
        let windowed = BondComma(); windowed.windowPosts = 3
        var closes = 0
        let waiter = NotificationSharing(transport: { windowed }, supported: { true }, bond: {}, device: { "comma-4" }, defaults: defaults,
                                         musicDone: { true }, closeMusicWindow: { closes += 1 }, pause: {})
        waiter.start()
        await settle(waiter) { $0 == .done }
        precondition(windowed.posts == 4 && closes == 3, "Waits through the music window, then bonds")
        let stuck = BondComma(); stuck.windowPosts = 1000
        var stuckCloses = 0
        let stalled = NotificationSharing(transport: { stuck }, supported: { true }, bond: {}, device: { "comma-5" }, defaults: defaults,
                                          musicDone: { false }, closeMusicWindow: { stuckCloses += 1 }, pause: {})
        stalled.start()
        await settle(stalled) { $0 == .message(NotificationSharing.musicWindowMessage) }
        precondition(stuckCloses == 0 && stuck.posts == NotificationSharing.musicWindowWaits + 1, "Gives up with a plain message")

        print("Phone notifications: not Bluetooth, old comma, busy, declined, timeout, disconnect, success and cancel passed")
    }
}
