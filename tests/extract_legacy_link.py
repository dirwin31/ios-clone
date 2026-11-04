from pathlib import Path
import sys
source = Path("GalaxyBluetooth/GalaxyBluetoothApp.swift").read_text()
start = source.index("struct LegacyGalaxyStatus:")
end = source.index("\n@MainActor", start)
probe = source[start:end]
tests = r'''
@main struct LegacyLinkRegression {
    @MainActor static func main() async throws {
        let first = "https://galaxy.firestar.link/AbCdEf0123456789"
        let second = "https://galaxy.firestar.link/ZyXwVu9876543210"
        precondition(LegacyGalaxyStatus(paired: true, url: first).browserURL?.absoluteString == first)
        precondition(LegacyGalaxyStatus(paired: true, url: second).browserURL?.absoluteString == second)
        for bad in ["https://galaxy.firestar.link", first + "?key=private", first + "#fragment", "http://galaxy.firestar.link/AbCdEf0123456789", "https://evil.example/AbCdEf0123456789", "https://galaxy.firestar.link:444/AbCdEf0123456789"] {
            precondition(LegacyGalaxyStatus(paired: true, url: bad).browserURL == nil)
        }
        let model = LinkModel()
        do { _ = try await model.confirmedTunnelURL(); preconditionFailure("Must require a direct connection") } catch {}
        model.bluetooth.connected = true
        model.bluetooth.responseURL = first
        let bluetoothURL = try await model.confirmedTunnelURL()
        precondition(bluetoothURL.absoluteString == first && model.bluetooth.calls == 1 && model.lan.calls == 0)
        model.bluetooth.changeSession = true
        do { _ = try await model.confirmedTunnelURL(); preconditionFailure("Must reject session change") } catch {}
        model.bluetooth.connected = false
        model.lan.connected = true
        model.lan.responseURL = second
        let lanURL = try await model.confirmedTunnelURL()
        precondition(lanURL.absoluteString == second && model.lan.calls == 1)
        model.lan.paired = false
        do { _ = try await model.confirmedTunnelURL(); preconditionFailure("Must reject unpaired comma") } catch {}
        model.lan.paired = true; model.lan.responseURL = "https://evil.example/private"
        do { _ = try await model.confirmedTunnelURL(); preconditionFailure("Must reject invalid URL") } catch {}
        print("Legacy Galaxy links: device-specific address preserved; general and unsafe links rejected")
    }
}
'''

start_method = source.index("    private func confirmedTunnelURL()")
end_method = source.index("    func acceptTunnel", start_method)
confirmation = source[start_method:end_method].replace("private func", "func")
stubs = r'''
enum BridgeError: Error { case message(String) }
struct Reply { var status = 200; var bodyData: Data }
@MainActor protocol GalaxyRequestTransport: AnyObject {
    var connected: Bool { get }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> Reply
}
@MainActor final class Direct: GalaxyRequestTransport {
    var connected = false, paired = true, changeSession = false
    var expectedDeviceID: String? = "saved"
    var generation = "local", sessionIdentifier = "bluetooth"
    var responseURL = "", calls = 0
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> Reply {
        precondition(path == "/api/galaxy/status" && method == "GET" && body.isEmpty)
        calls += 1
        if changeSession { generation += "changed"; sessionIdentifier += "changed" }
        return Reply(bodyData: try JSONSerialization.data(withJSONObject: ["paired": paired, "url": responseURL]))
    }
}
enum TunnelTransport { static func endpoint(_ text: String) -> URL? { LegacyGalaxyStatus(paired: true, url: text).browserURL } }
enum LANTransport { static func failureCode(_ error: Error) -> String { "error" } }
final class Log { func record(_ event: String) {} }
@MainActor final class LinkModel {
    let lan = Direct(), bluetooth = Direct(), connectionLog = Log()
'''
probe += stubs + confirmation + "}\n"

Path(sys.argv[1]).write_text("import Foundation\n" + probe + tests)
