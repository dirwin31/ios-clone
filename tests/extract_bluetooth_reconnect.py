from pathlib import Path
import sys
source = Path('GalaxyBluetooth/BluetoothTransport.swift').read_text()
start = source.index('    private func reconnectDecision(')
end = source.index('    func forgetSavedDevice()', start)
methods = source[start:end]
property_start = source.index('    var hasSavedDevice: Bool {')
property_end = source.index('    var diagnosticSummary:', property_start)
methods = source[property_start:property_end] + methods
settings = Path('GalaxyBluetooth/ConnectionSettingsView.swift').read_text()
ui_start = settings.index('    private var needsPairing: Bool {')
ui_end = settings.index('    private var connecting:', ui_start)
ui_property = settings[ui_start:ui_end].replace('private var needsPairing', 'var needsPairing')
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
    var reconnectNotBefore: TimeInterval = 0
    var failedConnections = 0
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
enum Mode { case automatic, bluetooth, lan }
struct Model { var mode = Mode.bluetooth; var pairingKey = String(repeating: "a", count: 64) }
struct SettingsProbe {
    var model = Model()
    let bluetooth = Probe()
    UI_PROPERTY
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
        let cooling = Probe(); cooling.central.cached = [Peripheral(saved)]
        cooling.reconnectNotBefore = ProcessInfo.processInfo.systemUptime + 24
        cooling.reconnectSaved(pairingKey: key)
        precondition(cooling.connects.isEmpty && cooling.central.lookups == 0, "Wait after failure, even when the previous attempt took longer than the retry delay")
        cooling.reconnectNotBefore = 0
        cooling.reconnectSaved(pairingKey: key)
        precondition(cooling.connects == [saved])
        let missing = Probe(); missing.reconnectSaved(pairingKey: "")
        precondition(missing.scans == 0 && missing.central.lookups == 0 && missing.status.contains("pairing"))
        UserDefaults.standard.saved = nil
        let noDevice = Probe(); noDevice.reconnectSaved(pairingKey: key)
        precondition(noDevice.scans == 0 && noDevice.status.contains("No saved"))
        var settings = SettingsProbe()
        precondition(settings.needsPairing, "A saved key without a peripheral must offer pairing, not a dead-end Connect button")
        UserDefaults.standard.saved = "invalid"
        precondition(settings.needsPairing, "An invalid peripheral ID must offer pairing")
        UserDefaults.standard.saved = saved.uuidString
        precondition(!settings.needsPairing, "A complete setup must retain reconnect")
        settings.model.pairingKey = ""
        precondition(settings.needsPairing, "A peripheral without a key still needs pairing")
        for mode in [Mode.lan, .automatic] {
            settings.model.mode = mode
            precondition(!settings.needsPairing, "Wi-Fi connections must not require Bluetooth setup")
        }
        UserDefaults.standard.saved = saved.uuidString
        let off = Probe(); off.central.state = .off; off.reconnectSaved(pairingKey: key)
        precondition(off.scans == 0 && off.central.lookups == 0)
        print("Bluetooth reconnect: cached device, targeted scan recovery, unrelated-device rejection, missing setup and powered-off guards passed")
    }
}
'''
Path(sys.argv[1]).write_text(probe + methods + tests.replace('UI_PROPERTY', ui_property))
