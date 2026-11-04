from pathlib import Path
import subprocess, tempfile
source = Path("GalaxyBluetooth/GalaxyBluetoothApp.swift").read_text()
start = source.index("@MainActor\nfinal class ConnectionEventLog")
end = source.index("    func report(model:", start)
probe = "import Foundation\nimport Combine\n" + source[start:end] + "}\n" + r''' 
@main struct LogRegression {
    @MainActor static func main() {
        let log = ConnectionEventLog()
        var publications = 0
        let observation = log.objectWillChange.sink { publications += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<30000 { log.record("event \(index)") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(log.events.count == 12000)
        precondition(log.events.first!.hasSuffix("event 18000"))
        precondition(log.events.last!.hasSuffix("event 29999"))
        precondition(publications == 0, "Recording must not invalidate SwiftUI")
        log.record("repeat"); log.record("repeat"); log.record("repeat"); log.record("next")
        precondition(log.events.dropLast().last!.contains("repeated 2 additional times"))
        let secret = String(repeating: "a", count: 64)
        log.record("error https://galaxy.firestar.link/private?token=secret " + secret + " Bearer private-token")
        precondition(!log.events.last!.contains(secret))
        precondition(!log.events.last!.contains("private-token"))
        precondition(!log.events.last!.contains("galaxy.firestar.link"))
        log.clear(); precondition(log.events.isEmpty)
        log.record("request failed HTTP 403 Bearer secret")
        for index in 0..<13000 { log.record("successful poll \(index)") }
        precondition(!log.events.contains { $0.contains("HTTP 403") })
        precondition(log.failureEvents.count == 1 && log.failureEvents[0].contains("HTTP 403"))
        precondition(!log.failureEvents[0].contains("Bearer secret"))
        for index in 0..<300 { log.record("request failed \(index)") }
        precondition(log.failureEvents.count == 256)
        precondition(log.failureEvents.first!.hasSuffix("request failed 44"))
        log.clear(); precondition(log.failureEvents.isEmpty)
        for event in ["Tunnel login rejected: missing session", "navigation blocked: destination", "web content process terminated"] {
            log.record(event)
        }
        precondition(log.failureEvents.count == 3, "Sign-in and browser failures must survive routine polling")
        log.clear()
        let beforeStates = publications
        for _ in 0..<10000 {
            log.recordState("bluetooth", "Bluetooth waiting")
            log.recordState("tunnel", "Tunnel waiting")
        }
        precondition(log.events.count == 2, "Interleaved repeated states must not flood the log")
        log.recordState("bluetooth", "Bluetooth connecting")
        precondition(log.events.count == 3)
        precondition(publications == beforeStates, "Detailed state logging must not invalidate SwiftUI")
        log.clear(); precondition(log.events.isEmpty)
        log.record("fresh"); precondition(log.events.count == 1)
        withExtendedLifetime(observation) {}
        print("Connection log: ordering, bounds, redaction, repeat summary, clear, and zero UI publications passed; 30000 events in \(elapsed)s")
    }
}
'''
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder)
    (path / "LogProbe.swift").write_text(probe)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(path / "cache"), str(path / "LogProbe.swift"), "-o", str(path / "probe")], check=True)
    subprocess.run([str(path / "probe")], check=True)
