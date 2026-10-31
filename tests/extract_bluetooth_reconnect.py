from pathlib import Path
import sys
source = Path('GalaxyBluetooth/BluetoothTransport.swift').read_text()
start = source.index('    private func reconnectDecision(')
end = source.index('    func forgetSavedDevice()', start)
methods = source[start:end]
probe = r'''
import Foundation
struct NearbyDevice { let id: UUID; let name: String; let signal: Int }
class Peripheral { let identifier: UUID; var name: String? = "comma"; init(_ id: UUID) { identifier = id } }
enum RadioState: Int { case off = 4, poweredOn = 5 }
class Central {
    var state = RadioState.poweredOn
    var cached: [Peripheral] = []
    var lookups = 0
    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [Peripheral] { lookups += 1; return cached.filter { ids.contains($0.identifier) } }
}
class FixtureDefaults { var saved: String?; func string(forKey: String) -> String? { saved } }
enum UserDefaults { static let standard = FixtureDefaults() }
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.init(repeating: 0, count: hex.count / 2)
    }
}
class Probe {
    var central = Central()
    var connected = false, connecting = false, isScanning = false
    var status = "", lastReconnectReason = ""
    var reconnectTarget: (id: UUID, key: String)?
    var onEvent: ((String) -> Void)?
    var peripherals: [UUID: Peripheral] = [:]
    var devices: [NearbyDevice] = []
    var scans = 0, connects: [UUID] = []
    func scan() { scans += 1; isScanning = true; reconnectTarget = nil }
    func connect(_ device: NearbyDevice, pairingKey: String) { connects.append(device.id); reconnectTarget = nil; isScanning = false; connecting = true }
'''
tests = r'''
    func discovered(_ id: UUID) {
        peripherals[id] = Peripheral(id)
        devices.append(NearbyDevice(id: id, name: "comma", signal: -45))
        reconnectDiscoveredDevice()
    }
}
@main struct ReconnectRegression {
    static func main() {
        let saved = UUID(), other = UUID(), key = String(repeating: "a", count: 64)
        UserDefaults.standard.saved = saved.uuidString
        let cached = Probe(); cached.central.cached = [Peripheral(saved)]
        cached.reconnectSaved(pairingKey: key)
        precondition(cached.connects == [saved] && cached.scans == 0)
        let recovery = Probe(); var events: [String] = []; recovery.onEvent = { events.append($0) }
        recovery.reconnectSaved(pairingKey: key)
        precondition(recovery.scans == 1 && recovery.connects.isEmpty)
        recovery.reconnectSaved(pairingKey: key)
        precondition(recovery.scans == 1, "Do not restart an in-flight recovery scan")
        recovery.discovered(other)
        precondition(recovery.connects.isEmpty, "Never reconnect to an unrelated nearby comma")
        recovery.discovered(saved)
        precondition(recovery.connects == [saved] && recovery.reconnectTarget == nil)
        precondition(!events.joined().contains(key))
        let missing = Probe(); missing.reconnectSaved(pairingKey: "")
        precondition(missing.scans == 0 && missing.central.lookups == 0 && missing.status.contains("pairing"))
        UserDefaults.standard.saved = nil
        let noDevice = Probe(); noDevice.reconnectSaved(pairingKey: key)
        precondition(noDevice.scans == 0 && noDevice.status.contains("No saved"))
        UserDefaults.standard.saved = saved.uuidString
        let off = Probe(); off.central.state = .off; off.reconnectSaved(pairingKey: key)
        precondition(off.scans == 0 && off.central.lookups == 0)
        print("Bluetooth reconnect: cached device, targeted scan recovery, unrelated-device rejection, missing setup and powered-off guards passed")
    }
}
'''
Path(sys.argv[1]).write_text(probe + methods + tests)
