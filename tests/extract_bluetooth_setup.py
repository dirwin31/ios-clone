from pathlib import Path
import sys
s = Path('GalaxyBluetooth/BluetoothTransport.swift').read_text()
a = s.index('    private func recordConnectionFailure(')
b = s.index('    var reconnectDelay:', a)
methods = s[a:b].replace('20_000_000_000', '3_000_000_000')
delay = s[b:s.index('\n', b)]
Path(sys.argv[1]).write_text('''import Foundation
@MainActor final class Probe {
 var failedConnections = 0
 var reconnectNotBefore: TimeInterval = 0
 var connectionAttempt = 1
 var connectionPhase = "idle"
 var connectionStarted = ProcessInfo.processInfo.systemUptime
 var phaseStarted: TimeInterval = 0
 var connectionTimeout: Task<Void, Never>?
 var connected = false
 var onEvent: ((String) -> Void)?
 var failures: [String] = []
 func failConnection(_ message: String) { failures.append(message) }
''' + methods + delay + '''
 func stage(_ phase: String) { beginConnectionPhase(phase) }
 func failure(at time: TimeInterval) { recordConnectionFailure(now: time) }
}
@main struct SetupTests {
 @MainActor static func main() async throws {
  let retry = Probe()
  retry.failure(at: 100)
  precondition(retry.reconnectNotBefore == 106)
  retry.failure(at: 200)
  precondition(retry.reconnectNotBefore == 212)
  retry.failure(at: 300)
  precondition(retry.reconnectNotBefore == 324)
  retry.failure(at: 400)
  precondition(retry.reconnectNotBefore == 424, "Bound retries and measure from failure, not attempt start")
  let setup = Probe()
  setup.stage("link")
  try await Task.sleep(nanoseconds: 1_500_000_000)
  setup.stage("services")
  try await Task.sleep(nanoseconds: 2_000_000_000)
  precondition(setup.failures.isEmpty, "Progress must cancel the earlier setup deadline")
  try await Task.sleep(nanoseconds: 2_000_000_000)
  precondition(setup.failures.count == 1 && setup.failures[0].contains("services"), "A stalled stage must still time out with its phase")
  setup.stage("authentication")
  setup.connected = true
  try await Task.sleep(nanoseconds: 3_200_000_000)
  precondition(setup.failures.count == 1, "A completed handshake cannot be timed out")
  setup.connected = false
  setup.stage("link")
  setup.connectionAttempt += 1
  try await Task.sleep(nanoseconds: 3_200_000_000)
  precondition(setup.failures.count == 1, "An older attempt's timeout cannot close a newer connection")
  print("Bluetooth setup: failure-relative backoff, stage progress, stalled stages, successful handshake and stale attempt guards passed")
 }
}
''')
