"""Exercise the production monitor's identity gate after a network handoff."""
from pathlib import Path
import subprocess
import tempfile

source = Path('GalaxyBluetooth/Navigation/NavigationModel.swift').read_text()
start = source.index('                // A route handoff')
end = source.index('                let requestedAt = Date()', start)
gate = source[start:end]
harness = r'''
import Foundation
@MainActor final class Connection {
    var identity = "comma-a"
    var session = "lan"
    var verified = false
    var checks = 0
    var onCheck: (() -> Void)?
    func ensureDeviceIdentity() async throws -> String {
        checks += 1; verified = true; onCheck?(); return identity
    }
}
@MainActor final class Monitor {
    var revision = 0
    var navigating = true
    var usingComma = true
    var commaIdentity = "comma-a"
    var accepted = false
    var rejected = false
    func clearCommaDisplay(_ message: String, discardRoute: Bool) { rejected = true }
    func step(_ connection: Connection) async throws {
        for _ in 0..<1 {
            let session = connection.session
            let revision = self.revision
__GATE__
            accepted = true
        }
    }
}
@main struct Regression {
    @MainActor static func main() async throws {
        let connection = Connection(), recovered = Monitor()
        try await recovered.step(connection)
        precondition(recovered.accepted && connection.verified && connection.checks == 1,
                     "Same comma must recover after its verification cache is invalidated")
        let other = Monitor(); connection.identity = "comma-b"
        try await other.step(connection)
        precondition(other.rejected && !other.accepted, "Never adopt another comma's route")
        let reset = Monitor(); connection.identity = "comma-a"
        connection.onCheck = { reset.revision += 1; reset.navigating = false }
        try await reset.step(connection)
        precondition(!reset.accepted && !reset.rejected, "Reset must invalidate pending verification")
        print("Navigation recovery: same comma, different comma, and reset during verification passed")
    }
}
'''.replace('__GATE__', gate)
acceptance = source[source.index('    private var routeAcceptanceExpiry:'):source.index('\n    }', source.index('    func showRouteAcceptance()')) + 6]
harness += '''
@MainActor final class TripNotice {
    var notice = ""
''' + acceptance + '''
}
'''
harness = harness.replace('        let connection = Connection(), recovered', '''
        let success = TripNotice(), ended = TripNotice()
        success.showRouteAcceptance()
        ended.showRouteAcceptance()
        precondition(!success.notice.isEmpty)
        ended.notice = "Route ended."
        try await Task.sleep(for: .milliseconds(3200))
        precondition(success.notice.isEmpty && ended.notice == "Route ended.")
        let connection = Connection(), recovered''')
services = Path('GalaxyBluetooth/Navigation/NavigationServices.swift').read_text()
poll = services[services.index('    private func syncGuidancePolling()'):services.rindex('}')]
harness += r"""
@MainActor final class TestNavigation {
    var navigating = true, usingComma = true
    var started: [String] = []
    var pending: [String: CheckedContinuation<Void, Never>] = [:]
    func monitorComma(connection: Connection, session: String) async {
        started.append(session)
        await withCheckedContinuation { pending[session] = $0 }
    }
}
@MainActor final class Handoff {
    let connection = Connection(), navigation = TestNavigation()
    var enabled = true, resetting = false
    var routeSession: String?
    var routeTask: Task<Void, Never>?
    func exercise() async {
        connection.session = "ble"
        syncGuidancePolling()
        while navigation.pending["ble"] == nil { await Task.yield() }
        connection.session = "lan"
        syncGuidancePolling()
        while navigation.pending["lan"] == nil { await Task.yield() }
        navigation.pending.removeValue(forKey: "ble")?.resume()
        for _ in 0..<10 { await Task.yield() }
        syncGuidancePolling()
        await Task.yield()
        precondition(navigation.started == ["ble", "lan"])
        navigation.navigating = false
        syncGuidancePolling()
        precondition(routeTask == nil)
        navigation.pending.removeValue(forKey: "lan")?.resume()
    }
__POLL__
}
""".replace('__POLL__', poll)
harness = harness.replace('        let connection = Connection(), recovered', '        await Handoff().exercise()\n        let connection = Connection(), recovered')
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root / 'Probe.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(root / 'cache'), str(root / 'Probe.swift'), '-o', str(root / 'probe')], check=True)
    subprocess.run([str(root / 'probe')], check=True)
