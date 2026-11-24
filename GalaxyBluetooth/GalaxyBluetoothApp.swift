import SwiftUI
import QuartzCore
import CoreImage
import Network
import MapKit
import CoreBluetooth
import StoreKit

@main
struct GalaxyBluetoothApp: App {
    @UIApplicationDelegateAdaptor(SentryAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @AppStorage("galaxy.app.language") private var language = "en"
    var body: some Scene { WindowGroup { GalaxyRootView(model: model).environment(\.locale, Locale(identifier: language)).onOpenURL { ShareInbox.shared.receive($0, model: model) }.modifier(ShareNotice()) } }
}

enum CompanionTab: String, CaseIterable, Identifiable {
    case galaxy = "Galaxy", navigation = "Navigation", live = "Live View", diagnostics = "Diagnostics", logs = "Logs & support", connections = "Settings"
    var id: String { rawValue }
    var isDeveloperPage: Bool { self == .live || self == .diagnostics }
    var icon: String {
        switch self {
        case .galaxy: "sparkles"
        case .navigation: "location.fill"
        case .live: "play.rectangle"
        case .diagnostics: "chart.xyaxis.line"
        case .logs: "ladybug"
        case .connections: "gearshape.fill"
        }
    }
}

struct LegacyGalaxyStatus: Decodable {
    let paired: Bool
    let url: String
    var browserURL: URL? {
        guard let parsed = URL(string: url), parsed.scheme == "https",
              parsed.host == "galaxy.firestar.link", parsed.port == nil,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              parsed.path.range(of: "^/[A-Za-z0-9]{16}$", options: .regularExpression) != nil else { return nil }
        return parsed
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let diagnostics = CompanionDiagnostics()
    let galaxyPage = GalaxyPageDiagnostics()
    let connectionLog = ConnectionEventLog()
    @Published private(set) var buildDistribution = "Unknown (StoreKit check pending)"
    private(set) var networkPathDiagnostics = "Not reported yet"

    private func identifyBuildDistribution() async {
        #if targetEnvironment(simulator)
        buildDistribution = "Development (simulator)"
        #elseif DEBUG
        buildDistribution = "Development (Debug configuration)"
        #else
        do {
            // Read the app transaction only; never force a receipt refresh or sign-in.
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                if transaction.environment == .production {
                    buildDistribution = "App Store (verified production app transaction)"
                } else if transaction.environment == .sandbox {
                    buildDistribution = "TestFlight / sandbox (verified sandbox app transaction)"
                } else if transaction.environment == .xcode {
                    buildDistribution = "Development (StoreKit Xcode environment)"
                } else {
                    buildDistribution = "Unknown (unrecognized StoreKit environment)"
                }
            case .unverified:
                buildDistribution = "Unknown (app transaction could not be verified)"
            }
        } catch {
            let failure = error as NSError
            buildDistribution = "Unknown (StoreKit error domain=\(failure.domain); code=\(failure.code))"
        }
        #endif
        connectionLog.record("Build distribution: " + buildDistribution)
    }
    let discovery = LANDiscovery()
    @Published var selectingDiscoveredComma = false
    private var lastRoute = "Reconnecting…"
    @Published var showDiagnostics = false
    @Published var showAudioPairing = false
    @Published var phoneMusicEnabled = UserDefaults.standard.bool(forKey: "galaxy.phoneMusic.enabled") {
        didSet {
            guard oldValue != phoneMusicEnabled else { return }
            UserDefaults.standard.set(phoneMusicEnabled, forKey: "galaxy.phoneMusic.enabled")
            if phoneMusicEnabled {
                if transport.connected && !pairingInProgress { startAudioPairing() }
            } else {
                offerAudioPairing = false
                audioWindowOpen = false
                showAudioPairing = false
                audioPairing.dismiss()
            }
        }
    }
    private var offerAudioPairing = false
    private var audioWindowOpen = false
    private let claimer = ClaimTransport()
    lazy var audioPairing = AudioPairing(transport: { [weak self] in self?.transport })
    lazy var phoneLocation: PhoneLocation = {
        let value = PhoneLocation(transport: { [weak self] in self?.transport })
        value.onEvent = { [weak self] in self?.connectionLog.record("GPS: " + $0) }
        value.onSharingChanged = { [weak self] _ in self?.updateMonitoring() }
        return value
    }()
    @Published var tab: CompanionTab = .connections {
        didSet {
            autoOpenGalaxyPending = false
            if tab == .galaxy { applyMatchedGalaxy() }
            else { galaxyPage.pendingStartupPage = nil }
        }
    }
    @Published var developerMode = UserDefaults.standard.bool(forKey: "galaxy.app.developerMode") {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: "galaxy.app.developerMode")
            if !developerMode {
                if tab.isDeveloperPage { tab = opened ? .galaxy : .connections }
                diagnostics.live = false
                diagnostics.phoneVisible = false
                showDiagnostics = false
            }
        }
    }
    @Published var navigationEnabled = UserDefaults.standard.object(forKey: "galaxy.app.navigationEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(navigationEnabled, forKey: "galaxy.app.navigationEnabled")
            navigationServices.setEnabled(navigationEnabled)
            if !navigationEnabled && tab == .navigation { tab = opened ? .galaxy : .connections }
        }
    }
    var connectionSetupBusy: Bool { pairingInProgress || offerAudioPairing || showAudioPairing }
    private var galaxyRecoveryTask: Task<Void, Never>?
    private var lastAutomaticGalaxyRecovery: TimeInterval = -.infinity
    func recoverGalaxy(automatic: Bool = true, reload: Bool = true) {
        guard phoneActive, galaxyRecoveryTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if automatic && reload {
            guard now - lastAutomaticGalaxyRecovery >= 30 else {
                galaxyPage.record("Automatic page recovery paused; use Retry Galaxy")
                return
            }
            lastAutomaticGalaxyRecovery = now
        }
        galaxyRecoveryTask = Task { @MainActor in
            defer { self.galaxyRecoveryTask = nil }
            let previousURL = self.server.url
            let healthy = await self.server.ensureAvailable()
            guard self.phoneActive else { return }
            if healthy {
                if self.opened && (reload || self.galaxyPage.stalled || previousURL != self.server.url) {
                    self.galaxyPage.record("Local server checked; recreating Galaxy web page")
                    self.galaxyPage.retry()
                }
            } else { self.galaxyPage.fail("Local server unavailable after recovery attempt") }
        }
    }
    lazy var navigationServices = NavigationServices(app: self)
    private var navigationActive = false
    func setNavigationActive(_ active: Bool) { navigationActive = active; updateMonitoring() }
    private var phoneActive = false
    private var carPlayActive = false
    private var monitorTask: Task<Void, Never>?
    func setPhoneActive(_ active: Bool) { connectionLog.record("Lifecycle: phone active=\(active); tab=\(tab.rawValue); navigation=\(navigationActive)"); phoneActive = active; if !active { automaticLAN?.cancel(); firstConnection?.cancel(); firstConnection = nil }; diagnostics.phoneActive = active; discovery.setActive(active); updateMonitoring() }
    func setCarPlayActive(_ active: Bool) { connectionLog.record("Lifecycle: CarPlay active=\(active)"); carPlayActive = active; diagnostics.carPlayActive = active; updateMonitoring() }
    private func updateMonitoring() {
        // Sharing phone GPS keeps the app running in the background, so keep reconnecting too.
        if phoneActive || carPlayActive || phoneLocation.sharing || navigationActive {
            if monitorTask == nil { monitorTask = Task { await monitor() } }
        } else { monitorTask?.cancel(); monitorTask = nil; tunnelProbeTask?.cancel() }
    }
    @Published var pairingKey = PairingKeyStore.load()
    @Published var address = UserDefaults.standard.string(forKey: "galaxy.lan.address") ?? ""
    @Published var findAddressAutomatically = UserDefaults.standard.object(forKey: "galaxy.lan.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(findAddressAutomatically, forKey: "galaxy.lan.auto") }
    }
    @Published var networkDetails = "Comma can use a hotspot, Wi-Fi or its SIM for internet. Your connection here controls how this iPhone reaches comma."
    @Published var mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "galaxy.connection.mode") ?? "") ?? .automatic {
        didSet {
            automaticLAN?.cancel(); lanProbeTask?.cancel(); firstConnection?.cancel(); firstConnection = nil
            transport.mode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "galaxy.connection.mode")
            if mode == .lan { bluetooth.disconnect() }
            if mode == .bluetooth { discovery.stop(); lan.invalidate(reason: "Bluetooth-only mode selected") }
            if mode != .automatic { tunnelProbeTask?.cancel(); tunnel.invalidate("Tunnel paused in " + mode.title) }
            if oldValue != mode { resumeAutomaticTunnel() }
            logConnection("Connection mode selected: \(mode.title)")
        }
    }
    @Published var connectionPriority = ConnectionRoute.normalized(UserDefaults.standard.stringArray(forKey: "galaxy.connection.priority") ?? []) {
        didSet {
            transport.priority = connectionPriority
            UserDefaults.standard.set(connectionPriority.map(\.rawValue), forKey: "galaxy.connection.priority")
            logConnection("Connection order changed")
        }
    }
    var connectionSession: String {
        switch transport.selectedRoute {
        case .lan: "lan-" + lan.generation
        case .tunnel: "tunnel-" + tunnel.generation
        case .bluetooth: "ble-" + bluetooth.sessionIdentifier
        case nil: "disconnected"
        }
    }
    private var tunnelProbeTask: Task<Void, Never>?
    private var lastTunnelProbe = Date.distantPast
    private func resumeAutomaticTunnel() {
        guard mode == .automatic else { return }
        // A user returning to Automatic should not inherit the paused route's cooldown.
        // The monitor starts the next check after any cancelled probe has unwound.
        lastTunnelProbe = .distantPast
        if tunnel.credential != nil {
            tunnel.invalidate("Tunnel check pending in Automatic")
        }
    }
    func forgetTunnel() {
        tunnelProbeTask?.cancel()
        tunnel.forget(); TunnelKeyStore.remove(); ShareInbox.shared.mirrorTunnel()
    }
    private func confirmedTunnelURL() async throws -> URL {
        let identity = lan.expectedDeviceID
        let localGeneration = lan.generation
        let bluetoothSession = bluetooth.sessionIdentifier
        let direct: any GalaxyRequestTransport
        let usingBluetooth: Bool
        if bluetooth.connected { direct = bluetooth; usingBluetooth = true }
        else if lan.connected { direct = lan; usingBluetooth = false }
        else {
            connectionLog.record("Tunnel link confirmation blocked: no verified Bluetooth or Local Wi-Fi connection")
            throw BridgeError.message("Connect to your comma over Bluetooth or Local Wi-Fi to confirm its Galaxy link first.")
        }
        connectionLog.record("Tunnel link confirmation started over \(usingBluetooth ? "Bluetooth" : "Local Wi-Fi")")
        do {
            let response = try await direct.request(path: "/api/galaxy/status", method: "GET", headers: [:], body: Data())
            try Task.checkCancellation()
            guard lan.expectedDeviceID == identity, direct.connected,
                  usingBluetooth ? bluetooth.sessionIdentifier == bluetoothSession : lan.generation == localGeneration else {
                throw BridgeError.message("Comma connection changed while confirming the link. Try again.")
            }
            guard response.status == 200 else {
                throw BridgeError.message("Comma link confirmation returned HTTP \(response.status). Try again over Bluetooth or Local Wi-Fi.")
            }
            let status = try JSONDecoder().decode(LegacyGalaxyStatus.self, from: response.bodyData)
            guard status.paired, let url = status.browserURL,
                  let normalized = TunnelTransport.endpoint(url.absoluteString) else {
                throw BridgeError.message("Set up Galaxy pairing on your comma before using Tunnel.")
            }
            connectionLog.record("Tunnel link confirmed directly with comma; paired=true; valid format=true")
            return normalized
        } catch {
            connectionLog.record("Tunnel link confirmation failed: " + LANTransport.failureCode(error))
            throw error
        }
    }
    func acceptTunnel(url: URL, cookie: String) async throws {
        // Never ask the tunnel to attest to its own link. Require a fresh direct read.
        let confirmedURL = try await confirmedTunnelURL()
        guard TunnelTransport.endpoint(url.absoluteString) == confirmedURL else {
            connectionLog.record("Tunnel setup rejected: entered link differs from comma's current link")
            throw BridgeError.message("This link doesn’t match your comma. Use Get link from comma, then sign in again.")
        }
        let candidate = TunnelTransport()
        connectionLog.record("Tunnel setup: verification started; saved comma identity=\(lan.expectedDeviceID != nil)")
        candidate.onDiagnostic = { [weak self] in self?.connectionLog.record("Tunnel setup: " + $0) }
        candidate.onEvent = { [weak self] in self?.connectionLog.record("Tunnel setup: " + $0) }
        defer { connectionLog.record("Tunnel setup: verification finished; verified=\(candidate.connected); cancelled=\(Task.isCancelled)") }
        let previousIdentity = lan.expectedDeviceID
        candidate.expectedDeviceID = previousIdentity
        try candidate.configure(TunnelCredential(url: url.absoluteString, cookie: cookie, deviceID: ""))
        guard await candidate.probe(), let credential = candidate.credential else { throw BridgeError.message(candidate.status) }
        try Task.checkCancellation()
        guard lan.expectedDeviceID == previousIdentity else {
            throw BridgeError.message("This tunnel belongs to a different comma.")
        }
        try TunnelKeyStore.save(credential)
        ShareInbox.shared.mirrorTunnel()
        connectionLog.record("Tunnel setup: verified credential saved to Keychain")
        tunnelProbeTask?.cancel()
        try tunnel.configure(credential)
        lan.bind(to: credential.deviceID)
        UserDefaults.standard.set(credential.deviceID, forKey: "galaxy.comma.identity")
        tunnel.expectedDeviceID = lan.expectedDeviceID
        wantsConnection = true
        mode = .automatic
        lastTunnelProbe = .distantPast
        probeTunnelConnection()
    }
    private func probeTunnelConnection() {
        guard mode == .automatic, (phoneActive || carPlayActive || navigationActive || phoneLocation.sharing), wantsConnection, tunnel.credential != nil,
              tunnelProbeTask == nil, Date().timeIntervalSince(lastTunnelProbe) >= 30 else { return }
        lastTunnelProbe = Date()
        if tunnel.expectedDeviceID != lan.expectedDeviceID {
            tunnel.expectedDeviceID = lan.expectedDeviceID
            tunnel.invalidate("Comma identity changed")
        }
        tunnelProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tunnelProbeTask = nil }
            let previousIdentity = self.tunnel.expectedDeviceID
            if await self.tunnel.probe(), let credential = self.tunnel.credential {
                try? TunnelKeyStore.save(credential)
                ShareInbox.shared.mirrorTunnel()
                if self.lan.expectedDeviceID == previousIdentity {
                    self.lan.bind(to: credential.deviceID)
                    UserDefaults.standard.set(credential.deviceID, forKey: "galaxy.comma.identity")
                }
            }
            self.objectWillChange.send()
        }
    }
    @Published var showConnections = false
    var bluetoothSetupRequired: Bool {
        mode == .bluetooth && (Data(hex: pairingKey)?.count != 32 || !bluetooth.hasSavedDevice)
    }

    var connectionStatusLabel: String {
        if transport.connected { return transport.label }
        if pairingInProgress { return "Pairing with comma…" }
        if bluetoothSetupRequired { return "Bluetooth pairing required" }
        return transport.label
    }

    @Published var pairingInProgress = false
    @Published var pairingFailure = ""
    @Published private(set) var pairingResetNeeded = false
    @Published var showBluetoothPermission = false
    @Published var opened = false
    @Published var connectionMessage = "Choose a connection, or use Automatic to follow your connection priority."
    @Published var wantsConnection = true
    @Published var loadingLegacyURL = false
    @Published var legacyMessage = ""
    @Published var legacyURL: URL?
    let bluetooth: BluetoothTransport
    let lan: LANTransport
    let tunnel: TunnelTransport
    let transport: PreferredTransport
    let assets: GalaxyAssetStore
    let server: LoopbackServer
    private let pathMonitor = NWPathMonitor()
    private var lastNetworkPath = ""
    private var lastReconnect = Date.distantPast
    private var lastAddressCheck = Date.distantPast
    private var identitySession = ""
    private var addressCheckSession = ""
    private var localAddressNetwork = ""
    private var initialDiscoveryStarted = false
    private var firstSetupAttempt: (search: Int, address: String, time: TimeInterval)?
    var connectionControllerDiagnostics: String {
        "Connection controller: requested=\(wantsConnection); phone active=\(phoneActive); CarPlay active=\(carPlayActive); monitor running=\(monitorTask != nil); setup busy=\(connectionSetupBusy); selecting device=\(selectingDiscoveredComma)\n"
        + "Connection tasks: first setup=\(firstConnection != nil); automatic LAN=\(automaticLAN != nil); LAN probe=\(lanProbeTask != nil); Tunnel probe=\(tunnelProbeTask != nil); pairing=\(pairingTask != nil)\n"
        + "Address discovery: initial search started=\(initialDiscoveryStarted); Bluetooth lookup enabled=\(findAddressAutomatically); addresses queued for automatic verification this search=\(triedLANAddresses.count); saved address present=\(!address.isEmpty)\n"
        + "Last discovered-device check: " + (lastDiscoveredDeviceCheck ?? "No check attempted this session")
    }
    private var lastDiscoveredDeviceCheck: String?
    private func discoveryCheck(_ message: String) {
        lastDiscoveredDeviceCheck = message
        connectionLog.recordState("discovered-device-check", "Discovered-device check: " + message)
    }

    private func discoveryTransport(for address: String, context: String) -> LANTransport {
        let candidate = LANTransport()
        let log: (String) -> Void = { [weak self] event in
            self?.connectionLog.record("\(context) \(address): \(event)")
        }
        candidate.onDiagnostic = log
        candidate.onEvent = log
        return candidate
    }
    private var firstConnection: Task<Void, Never>?
    var autoOpenGalaxyPending = true
    private var automaticLAN: Task<Void, Never>?
    private var lanProbeTask: Task<Void, Never>?
    private var lastLANDiscovery = Date.distantPast
    private var triedLANAddresses = Set<String>()
    private var pairingTask: Task<Void, Never>?
    var hasLANPairingSetup: Bool {
        lan.expectedDeviceID != nil && (try? LANTransport.endpoint(address)) != nil
    }
    func pairWithComma() {
        guard !pairingInProgress else { return }
        guard hasLANPairingSetup else {
            pairingFailure = "Connect to your comma over Local Wi-Fi first, then set up Bluetooth."
            connectionMessage = pairingFailure
            return
        }
        pairingInProgress = true
        pairingFailure = ""
        offerAudioPairing = false
        showAudioPairing = false
        bluetooth.disconnect(reason: "Starting new phone pairing")
        connectionMessage = "Preparing Bluetooth setup over Local Wi-Fi…"
        pairingTask = Task { @MainActor in
            defer { pairingInProgress = false; pairingTask = nil }
            do {
                // Bluetooth-only invalidates the normal LAN session. Use a separate, identity-checked
                // connection just for opening the pairing window; do not change the selected route.
                let pairingLAN = discoveryTransport(for: address, context: "Bluetooth pairing via LAN")
                pairingLAN.bind(to: lan.expectedDeviceID)
                if !lan.connected, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    connectionMessage = "Checking comma over Local Wi-Fi before Bluetooth pairing…"
                    try pairingLAN.configure(address: address)
                    _ = await pairingLAN.probe()
                }
                try Task.checkCancellation()
                let windowLAN = lan.connected ? lan : pairingLAN
                guard windowLAN.connected else {
                    throw BridgeError.message("Connect to your comma over Local Wi-Fi first. Its saved LAN address could not be verified.")
                }
                // Bind the Bluetooth reply to the comma whose LAN pairing window we open.
                let adapterResponse = try? await windowLAN.request(path: "/api/bluetooth/status", method: "GET", headers: [:], body: Data())
                let adapter = adapterResponse.flatMap { $0.status == 200 ? AudioPairing.parse($0.bodyData) : nil }
                let expectedAdapter = adapter.flatMap { AudioPairing.validAddress($0.adapterAddress) ? $0.adapterAddress : nil }
                try Task.checkCancellation()
                connectionLog.record("Pairing target adapter verification available=\(expectedAdapter != nil)")
                connectionLog.record("Opening phone pairing window over verified LAN")
                guard try await LANPairing.openWindow(over: windowLAN, progress: { self.connectionMessage = $0 }) else {
                    throw BridgeError.message("Local Wi-Fi disconnected before Bluetooth setup. Reconnect to comma over Local Wi-Fi and try again.")
                }
                connectionMessage = "Opened comma’s pairing window over Local Wi-Fi. Looking for comma…"
                connectionLog.record("Phone pairing window opened over verified LAN")
                try Task.checkCancellation()
                importClaim(try await claimer.claim(name: UIDevice.current.name, expectedAdapterAddress: expectedAdapter))
            }
            catch is CancellationError { connectionMessage = "Pairing cancelled." }
            catch {
                pairingFailure = error.localizedDescription
                connectionMessage = pairingFailure
                connectionLog.record("Phone pairing preparation or claim failed: " + error.localizedDescription)
            }
        }
    }
    func cancelPairing() { pairingTask?.cancel(); claimer.cancel() }
    private func importClaim(_ outcome: ClaimTransport.Outcome) {
        // The key is saved only after the encrypted handshake, like any imported key.
        opened = false
        wantsConnection = true
        bluetooth.forgetSavedDevice()
        PairingKeyStore.stage(PairingCode(key: outcome.result.key, id: outcome.result.id))
        lan.clearEndpoint()
        lan.bind(to: nil)
        address = ""
        identitySession = ""
        addressCheckSession = ""
        UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
        UserDefaults.standard.removeObject(forKey: "galaxy.lan.address")
        UserDefaults.standard.set(outcome.deviceID.uuidString, forKey: "galaxy.bluetooth.device")
        pairingKey = outcome.result.key
        if mode == .lan { mode = .automatic }
        connectionMessage = "Paired. Connecting to comma…"
        offerAudioPairing = phoneMusicEnabled
        audioWindowOpen = phoneMusicEnabled
        lastReconnect = Date()
        bluetooth.reconnectSaved(pairingKey: pairingKey)
        if !bluetooth.connecting { bluetooth.scan() }
    }
    init() {
        let bluetooth = BluetoothTransport()
        let lan = LANTransport()
        let tunnel = TunnelTransport()
        let transport = PreferredTransport(lan: lan, bluetooth: bluetooth, tunnel: tunnel, invalidateTunnel: { tunnel.invalidate($0) }, invalidateLAN: { lan.invalidate(reason: $0) })
        let assets = GalaxyAssetStore()
        self.bluetooth = bluetooth; self.lan = lan; self.tunnel = tunnel; self.transport = transport; self.assets = assets
        SentryPush.shared.transport = transport
        lan.bind(to: UserDefaults.standard.string(forKey: "galaxy.comma.identity"))
        if let credential = TunnelKeyStore.load() { try? tunnel.configure(credential) }
        tunnel.expectedDeviceID = lan.expectedDeviceID
        let cache = GalaxyReadCache(transport: transport, sessionID: {
            transport.selectedRoute == .tunnel ? "tunnel-" + tunnel.generation : transport.usesLAN ? "lan-" + lan.generation : "ble-" + bluetooth.sessionIdentifier
        })
        server = LoopbackServer(transport: cache, webRoot: assets.readyRoot)
        transport.mode = mode
        transport.priority = connectionPriority
        diagnostics.transport = transport; diagnostics.lan = lan
        galaxyPage.recover = { [weak self] automatic in self?.recoverGalaxy(automatic: automatic) }
        server.start()
        discovery.onEvent = { [weak self] reason in self?.connectionLog.record(reason) }
        discovery.onDevicesChanged = { [weak self] in self?.discoverAutomaticLAN() }
        lan.onDiagnostic = { [weak self] in self?.connectionLog.record($0) }
        transport.onDiagnostic = { [weak self] in self?.connectionLog.record($0) }
        tunnel.onDiagnostic = { [weak self] in self?.connectionLog.record($0) }
        tunnel.onEvent = { [weak self] reason in self?.objectWillChange.send(); self?.logConnection(reason) }
        lan.onEvent = { [weak self] reason in
            guard let self else { return }
            if self.lan.connected, let identity = self.lan.verifiedDeviceID {
                UserDefaults.standard.set(identity, forKey: "galaxy.comma.identity")
            }
            if self.tunnel.expectedDeviceID != self.lan.expectedDeviceID {
                self.tunnel.expectedDeviceID = self.lan.expectedDeviceID
                self.tunnel.invalidate("Comma identity changed")
            }
            self.logConnection(reason)
        }
        bluetooth.onEvent = { [weak self] reason in self?.logConnection(reason) }
        claimer.onEvent = { [weak self] reason in
            guard let self else { return }
            self.connectionLog.record(reason)
            if self.pairingInProgress {
                if reason == "Phone pairing started" { self.connectionMessage = "Starting Bluetooth…" }
                else if reason == "Phone pairing found comma; connecting" { self.connectionMessage = "Connecting to comma…" }
                else if reason == "Phone pairing connected; discovering service" { self.connectionMessage = "Checking Bluetooth service…" }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let route = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
                let reason = "iOS network path updated: \(path.status == .satisfied ? "available" : "unavailable"), \(route), expensive=\(path.isExpensive), constrained=\(path.isConstrained); IPv4=\(path.supportsIPv4); IPv6=\(path.supportsIPv6); DNS=\(path.supportsDNS); unsatisfied reason=\(String(describing: path.unsatisfiedReason))"
                let interfaces = path.availableInterfaces
                    .filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.name):\($0.index)" }.sorted().joined(separator: ",")
                self.networkPathDiagnostics = reason
                let fingerprint = "\(path.status)|\(route)|\(interfaces)|ipv4=\(path.supportsIPv4)|\(LANDiscovery.networkSignature())"
                guard fingerprint != self.lastNetworkPath else { return }
                self.lastNetworkPath = fingerprint
                self.connectionLog.record(reason)
                self.automaticLAN?.cancel(); self.lanProbeTask?.cancel()
                self.firstConnection?.cancel(); self.firstConnection = nil
                self.initialDiscoveryStarted = false
                self.pairingResetNeeded = false
                self.discovery.networkChanged()
                self.triedLANAddresses.removeAll()
                self.lastLANDiscovery = .distantPast
                self.lan.invalidate(reason: reason)
                self.tunnelProbeTask?.cancel()
                self.tunnel.invalidate("Network changed")
                self.lastTunnelProbe = .distantPast
                self.lastAddressCheck = .distantPast
                self.discoverAutomaticLAN()
            }
        }
        Task { [weak self] in await self?.identifyBuildDistribution() }
        pathMonitor.start(queue: .main)
        updateMonitoring()
        ShareInbox.shared.attach(self)
    }
    deinit { pathMonitor.cancel() }
    private func logConnection(_ reason: String) {
        let route = transport.label
        if route != lastRoute {
            connectionLog.record("\(lastRoute) → \(route): \(reason)")
            lastRoute = route
        } else { connectionLog.record("\(route): \(reason)") }
    }
    func connect() {
        legacyURL = nil
        do {
            if mode != .bluetooth, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try lan.configure(address: address)
            } else if mode != .bluetooth {
                discovery.start()
            }
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "galaxy.lan.address")
            wantsConnection = true
            lastReconnect = .distantPast
            lastTunnelProbe = .distantPast
            lastAddressCheck = .distantPast
            localAddressNetwork = ""
            connectionMessage = "Checking your comma…"
        } catch { connectionMessage = error.localizedDescription }
    }
    func startAudioPairing() {
        guard phoneMusicEnabled, transport.connected else { return }
        audioPairing.onEvent = { [weak self] event in self?.connectionLog.record(event) }
        connectionLog.record("Music setup using " + transport.label)
        showAudioPairing = true
        let windowOpen = audioWindowOpen
        audioWindowOpen = false
        audioPairing.start(windowOpen: windowOpen)
    }
    private var openingGalaxy = false
    @Published private(set) var matchingGalaxy = false
    private var lastGalaxyMatch = Date.distantPast

    func applyMatchedGalaxy() {
        guard opened, let root = assets.readyRoot, root != assets.inUseRoot else { return }
        assets.inUseRoot = root
        server.useWebRoot(root)
        galaxyPage.retry()
    }

    private var softwareReportSession = ""
    private var softwareReport = "Comma software: unavailable; no verified connection has reported it yet."
    private var softwareReportDate: Date?
    var commaSoftwareDiagnostics: String {
        guard let date = softwareReportDate else { return softwareReport }
        return softwareReport + "\nSoftware observed: " + ISO8601DateFormatter().string(from: date)
            + "\nSoftware snapshot matches current connection: " + String(transport.connected && softwareReportSession == connectionSession)
    }
    private func collectSoftwareDiagnostics() async {
        let session = connectionSession
        guard transport.connected, softwareReportSession != session else { return }
        softwareReportSession = session
        do {
            let response = try await transport.request(path: "/api/software/status?history=0", method: "GET", headers: [:], body: Data())
            guard connectionSession == session else { return }
            guard response.status == 200,
                  let json = try JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any],
                  let installed = json["installed"] as? [String: Any] else {
                softwareReport = "Comma software: unavailable (HTTP \(response.status) or unsupported response)."
                softwareReportDate = Date(); return
            }
            func field(_ value: Any?) -> String {
                guard let text = value as? String, !text.isEmpty else { return "not reported" }
                return String(text.filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(160))
            }
            let operations = json["operations"] as? [String: Any]
            let repository = (operations?["repository"] ?? json["repository"]) as? String
            // Only report owner/repo, never a remote URL containing credentials.
            let safeRepo = repository.flatMap { $0.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? $0 : nil }
            softwareReport = "Comma repository: \(field(safeRepo))\nComma branch: \(field(installed["branch"]))\nComma version: \(field(installed["version"]))\nComma display version: \(field(installed["displayVersion"]))\nComma commit: \(field(installed["commit"]))\nRestart history: not reported by this endpoint; a runtime-instance change alone does not prove a full device reboot."
            softwareReportDate = Date()
        } catch {
            guard connectionSession == session else { return }
            softwareReport = "Comma software: unavailable (" + LANTransport.failureCode(error) + ")."
            softwareReportDate = Date()
        }
    }

    func checkGalaxyUpdates() async {
        guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected, !matchingGalaxy else { return }
        matchingGalaxy = true
        lastGalaxyMatch = Date()
        defer { matchingGalaxy = false }
        // Pin both the manifest and asset files to one verified network session.
        let mode = self.mode
        let screenRoute = transport.galaxyScreenRoute
        if let screenRoute {
            let source: any GalaxyRequestTransport = screenRoute == .lan ? lan : tunnel
            let generation = screenRoute == .lan ? lan.generation : tunnel.generation
            let stillCurrent = {
                self.wantsConnection && self.mode == mode && source.connected &&
                generation == (screenRoute == .lan ? self.lan.generation : self.tunnel.generation)
            }
            connectionLog.recordState("galaxy-screen-source", "Galaxy screens: checking over " + screenRoute.title)
            await assets.check(fetch: { path, _ in
                let response = path.hasPrefix("/api/") ? try await source.request(path: path, method: "GET", headers: [:], body: Data()) : try await source.page(path: path)
                return (response.status, response.bodyData)
            }, stillCurrent: stillCurrent)
            if stillCurrent(), tab != .galaxy || !galaxyPage.mounted { applyMatchedGalaxy() }
        } else {
            let bluetooth = self.bluetooth
            let session = bluetooth.sessionIdentifier
            connectionLog.recordState("galaxy-screen-source", "Galaxy screens: checking version over Bluetooth")
            await assets.checkBluetoothManifest(fetch: { path, _ in
                let response = try await bluetooth.request(path: path, method: "GET", headers: [:], body: Data())
                return (response.status, response.bodyData)
            }, stillCurrent: { self.wantsConnection && self.mode == mode && bluetooth.connected && bluetooth.sessionIdentifier == session })
        }
        connectionLog.recordState("galaxy-screen-status", "Galaxy screens: " + assets.status)
        await collectSoftwareDiagnostics()
    }
    func openIfReady() {
        if transport.connected { pairingResetNeeded = false }
        guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected else { return }
        if opened { openGalaxyIfRequested(); return }
        guard !openingGalaxy else { return }
        openingGalaxy = true
        Task { @MainActor in
            defer { openingGalaxy = false }
            if transport.galaxyScreenRoute != nil ? Date().timeIntervalSince(lastGalaxyMatch) > 15 : assets.readyRoot != nil && !matchingGalaxy {
                await checkGalaxyUpdates()
            }
            guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected, !opened else { return }
            // Bluetooth Galaxy runs from screens saved from comma; the first download needs Wi-Fi/LAN.
            // Over Wi-Fi/LAN an older comma that cannot share its screens still opens, read live.
            guard let root = assets.readyRoot else {
                guard transport.usesNetwork else { return }
                assets.inUseRoot = nil
                opened = true
                openGalaxyIfRequested()
                return
            }
            assets.inUseRoot = root
            server.useWebRoot(root)
            opened = true
            openGalaxyIfRequested()
        }
    }
    func openGalaxyIfRequested() {
        guard phoneActive, autoOpenGalaxyPending, tab == .connections else { return }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppPreference.openGalaxy) as? Bool != false else {
            autoOpenGalaxyPending = false
            return
        }
        let choice = defaults.string(forKey: AppPreference.startupPage) ?? "/"
        if let screen = CompanionTab(rawValue: choice), screen != .galaxy {
            autoOpenGalaxyPending = false
            guard (!screen.isDeveloperPage || developerMode), (screen != .navigation || navigationEnabled) else { return }
            tab = screen
            diagnostics.live = screen == .live
            return
        }
        guard opened, transport.connected, !pairingInProgress, !offerAudioPairing, !showAudioPairing else { return }
        autoOpenGalaxyPending = false
        galaxyPage.pendingStartupPage = StartupPage.valid(choice) ? choice : "/"
        tab = .galaxy
    }
    func disconnect() {
        legacyURL = nil
        automaticLAN?.cancel(); lanProbeTask?.cancel()
        discovery.stop()
        firstConnection?.cancel(); firstConnection = nil; autoOpenGalaxyPending = false
        tunnelProbeTask?.cancel(); tunnel.invalidate("Disconnected")
        wantsConnection = false; opened = false
        bluetooth.disconnect(reason: "User selected Disconnect"); lan.invalidate(reason: "User selected Disconnect")
        connectionMessage = "Disconnected."
    }
    func resetPairingForReconnect() {
        cancelPairing()
        disconnect()
        bluetooth.forgetSavedDevice()
        PairingKeyStore.remove()
        pairingKey = ""
        lan.bind(to: nil)
        UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
        forgetTunnel()
        address = ""
        lan.clearEndpoint()
        UserDefaults.standard.removeObject(forKey: "galaxy.lan.address")
        pairingFailure = ""
        pairingResetNeeded = false
        mode = .lan
        wantsConnection = true
        initialDiscoveryStarted = true
        connectionMessage = "Looking for your comma. After Local Wi-Fi connects, choose Bluetooth to set up pairing again."
        discovery.start()
        connectionLog.record("User reset app pairing; searching Local Wi-Fi")
    }
    func selectDiscoveredComma(_ device: DiscoveredComma, userSelected: Bool = true) async -> Bool {
        guard !selectingDiscoveredComma, mode != .bluetooth else { return false }
        if userSelected { pairingResetNeeded = false }
        selectingDiscoveredComma = true
        firstSetupAttempt = (discovery.attempt, device.address, ProcessInfo.processInfo.systemUptime)
        automaticLAN?.cancel()
        lanProbeTask?.cancel()
        discovery.stop()
        defer { selectingDiscoveredComma = false }
        // Advertised names and addresses are discovery hints, not pairing credentials.
        let candidate = discoveryTransport(for: device.address, context: "Selected comma")
        discoveryCheck("Verifying \(device.address):8082 after \(userSelected ? "user selection" : "first-time discovery")")
        // Explicit local-only selection can recover an old runtime pin or choose another comma.
        // Never apply that permission to background discovery or another saved transport.
        if !userSelected || !pairingKey.isEmpty || tunnel.credential != nil {
            candidate.bind(to: lan.expectedDeviceID)
        }
        let originalGeneration = lan.generation
        let originalMode = mode
        do {
            try candidate.configure(address: device.address)
            guard await candidate.probe() else {
                if userSelected && candidate.pairingIdentityMismatch && !Task.isCancelled
                    && lan.generation == originalGeneration && mode == originalMode {
                    pairingResetNeeded = true
                }
                connectionMessage = "Couldn’t connect to \(device.address): \(candidate.status)"
                discoveryCheck("Selected comma \(device.address) rejected: \(candidate.status)")
                return false
            }
            guard !Task.isCancelled, lan.generation == originalGeneration, mode == originalMode, phoneActive else {
                connectionMessage = "Connection changed. Select the comma again."
                discoveryCheck("Selected comma check interrupted after verification; connection or app state changed")
                return false
            }
            lan.bind(to: candidate.verifiedDeviceID)
            pairingResetNeeded = false
            UserDefaults.standard.set(candidate.verifiedDeviceID, forKey: "galaxy.comma.identity")
            address = device.address
            connect()
            guard await lan.probe() else {
                connectionMessage = "Couldn’t connect to \(device.address): \(lan.status)"
                discoveryCheck("Selected comma \(device.address) failed final verification: \(lan.status)")
                return false
            }
            openIfReady()
            discoveryCheck("Discovered comma selected; LAN verification passed")
            return true
        } catch {
            connectionMessage = "Couldn’t connect to the discovered comma. Try again or enter its IP."
            discoveryCheck("Selected comma address rejected before verification: \(LANTransport.failureCode(error))")
            return false
        }
    }
    func fetchLegacyURL() async -> URL? {
        guard !loadingLegacyURL else { return nil }
        legacyMessage = ""; legacyURL = nil
        loadingLegacyURL = true
        defer { loadingLegacyURL = false }
        do {
            let url = try await confirmedTunnelURL()
            legacyURL = url
            let savedLink = tunnel.credential.flatMap { TunnelTransport.endpoint($0.url) }
            connectionLog.record("Comma-specific Galaxy link obtained directly; saved link present=\(savedLink != nil); matches saved link=\(savedLink == url); remote reachability not yet checked")
            return url
        } catch {
            connectionLog.record("Comma-specific legacy Galaxy link unavailable")
            legacyMessage = (error as? BridgeError)?.localizedDescription ?? "Couldn’t get your comma’s Galaxy link. Check Bluetooth or Local Wi-Fi and try again."
            return nil
        }
    }
    private func learnAddress() async {
        guard bluetooth.connected, Date().timeIntervalSince(lastAddressCheck) >= 20 || addressCheckSession != bluetooth.sessionIdentifier else { return }
        lastAddressCheck = Date()
        let session = bluetooth.sessionIdentifier
        let networkPath = lastNetworkPath
        addressCheckSession = session
        do {
            if identitySession != session || !lan.connected {
                let identity = try await bluetooth.request(path: "/data/runtime.json", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session else { return }
                // Only the authenticated BLE peer may establish the automatic LAN identity.
                guard identity.status == 200, let value = LANTransport.deviceID(identity.bodyData) else {
                    networkDetails = "Automatic local discovery needs a registered device identifier. Bluetooth still works; enter comma’s IP manually for Local Wi-Fi."
                    return
                }
                let status = try? await bluetooth.request(path: "/api/galaxy/status", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session else { return }
                let persistent = status.flatMap { $0.status == 200 ? LANTransport.persistentIdentity($0.bodyData) : nil }
                let verified = persistent ?? value
                lan.bind(to: verified)
                UserDefaults.standard.set(verified, forKey: "galaxy.comma.identity")

                identitySession = session
            }
            let network = session + "|" + networkPath
            guard findAddressAutomatically, !lan.connected, localAddressNetwork != network else { return }
            let generation = lan.generation
            let response = try await bluetooth.request(path: "/api/local-access", method: "GET", headers: [:], body: Data())
            guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session, response.status == 200,
                  lastNetworkPath == networkPath, lan.generation == generation, !lan.connected,
                  !response.bodyData.isEmpty else { return }
            if let ip = LANTransport.reportedAddress(response.bodyData) {
                connectionLog.record("Comma address learned over Bluetooth: \(ip):8082; previous=\(lan.endpoint?.host ?? "none")")
                localAddressNetwork = network
                try lan.configure(address: ip)
                address = ip
                UserDefaults.standard.set(ip, forKey: "galaxy.lan.address")
                networkDetails = "Trying comma’s current local address. If this hotspot or Wi-Fi network blocks direct access, Bluetooth stays available."
            } else {
                networkDetails = "Comma has no usable local Wi-Fi address. Bluetooth still controls local settings; comma can use its SIM for online downloads."
            }
            // Galaxy's online:true means the server responds, not that comma can reach the internet.
        } catch {
            // Discovery is optional; record evidence without disrupting working BLE.
            connectionLog.recordState("bluetooth-address-error", "Bluetooth address/identity lookup failed: \(LANTransport.failureCode(error)); cancelled=\(Task.isCancelled)")
        }
    }
    private func discoverAutomaticLAN() {
        guard phoneActive, wantsConnection, mode != .bluetooth, !connectionSetupBusy,
              !selectingDiscoveredComma, !lan.connected else { return }
        if lan.expectedDeviceID == nil, !pairingKey.isEmpty, !discovery.devices.isEmpty, lan.endpoint == nil {
            connectionLog.recordState("discovery-selection", "Automatic selection skipped: Bluetooth key saved without a saved comma identity; waiting for the user to select a discovered comma")
        }
        if lan.expectedDeviceID == nil && pairingKey.isEmpty {
            if !initialDiscoveryStarted {
                initialDiscoveryStarted = true
                discovery.start()
            }
            guard firstConnection == nil, discovery.devices.count == 1 else { return }
            let candidate = discovery.devices[0]
            if let previous = firstSetupAttempt, previous.search == discovery.attempt,
               previous.address == candidate.address {
                // Give a temporarily unreachable peer time to recover and resolve
                // a fresh address before automatically checking it again.
                if ProcessInfo.processInfo.systemUptime - previous.time >= 60 { discovery.start() }
                return
            }
            let search = discovery.attempt
            firstConnection = Task { @MainActor in
                defer { self.firstConnection = nil }
                // Allow other advertisements to arrive before choosing an unpaired device.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.phoneActive, self.wantsConnection, self.mode != .bluetooth,
                      !self.connectionSetupBusy, self.lan.expectedDeviceID == nil,
                      self.pairingKey.isEmpty, self.discovery.devices.count == 1,
                      !self.selectingDiscoveredComma, self.discovery.attempt == search,
                      self.discovery.devices[0].id == candidate.id,
                      self.discovery.devices[0].address == candidate.address else { return }
                self.connectionLog.record("First setup: verifying the only discovered comma")
                _ = await self.selectDiscoveredComma(candidate, userSelected: false)
            }
            return
        }
        // A saved address can belong to a previous hotspot in either Wi-Fi-capable mode.
        // Keep discovery identity-checked rather than requiring repeated manual attempts.
        guard phoneActive, wantsConnection, mode != .bluetooth,
              !pairingInProgress, !selectingDiscoveredComma, !lan.connected,
              let identity = lan.expectedDeviceID else { return }
        if !discovery.searching, Date().timeIntervalSince(lastLANDiscovery) >= 20 {
            lastLANDiscovery = Date()
            triedLANAddresses.removeAll()
            discovery.start()
        }
        guard automaticLAN == nil else { return }
        let addresses = discovery.devices.map(\.address).filter { !triedLANAddresses.contains($0) }
        guard !addresses.isEmpty else { return }
        triedLANAddresses.formUnion(addresses)
        let generation = lan.generation
        automaticLAN = Task { @MainActor in
            defer { self.automaticLAN = nil }
            let stillCurrent = {
                self.phoneActive && self.wantsConnection && self.mode != .bluetooth
                    && !self.pairingInProgress && !self.selectingDiscoveredComma && !self.lan.connected
                    && self.lan.generation == generation && self.lan.expectedDeviceID == identity
            }
            var mismatchedAddress: String?
            let address = await LANDiscoveryMatch.first(addresses: addresses, expectedDeviceID: identity, stillCurrent: stillCurrent) { address, identity in
                let candidate = self.discoveryTransport(for: address, context: "Automatic LAN verification")
                candidate.bind(to: identity)
                do { try candidate.configure(address: address) }
                catch {
                    self.discoveryCheck("Automatic candidate \(address) rejected before verification: \(LANTransport.failureCode(error))")
                    return false
                }
                let verified = await candidate.probe()
                guard stillCurrent() else { return false }
                self.discoveryCheck("Automatic candidate \(address): \(candidate.status)")
                if candidate.pairingIdentityMismatch { mismatchedAddress = address }
                return verified
            }
            guard !Task.isCancelled, stillCurrent() else { return }
            guard let address else {
                if let mismatchedAddress, self.discovery.devices.count == 1,
                   self.discovery.devices.first?.address == mismatchedAddress {
                    self.pairingResetNeeded = true
                }
                return
            }
            self.pairingResetNeeded = false
            do { try self.lan.configure(address: address) } catch { return }
            self.address = address
            UserDefaults.standard.set(address, forKey: "galaxy.lan.address")
            if await self.lan.probe() {
                self.discovery.stop()
                self.connectionLog.record("Automatic Local Wi-Fi discovery verified the paired comma")
            }
        }
    }

    private func probeLocalConnection() {
        guard !selectingDiscoveredComma, lanProbeTask == nil else { return }
        lanProbeTask = Task { @MainActor in
            defer { self.lanProbeTask = nil }
            await self.learnAddress()
            guard !Task.isCancelled, self.wantsConnection, self.mode != .bluetooth else { return }
            if self.lan.endpoint == nil, !self.address.isEmpty {
                do { try self.lan.configure(address: self.address) }
                catch { self.connectionMessage = error.localizedDescription }
            }
            _ = await self.lan.probe()
            if !Task.isCancelled, self.lan.connected { self.discovery.stop() }
        }
    }

    func monitor() async {
        while !Task.isCancelled {
            connectionLog.recordState("monitor", "Connection monitor: requested=\(wantsConnection); mode=\(mode.rawValue); pairing=\(pairingInProgress); selecting device=\(selectingDiscoveredComma); Bluetooth key saved=\(!pairingKey.isEmpty); Bluetooth connected=\(bluetooth.connected); connecting=\(bluetooth.connecting); scanning=\(bluetooth.isScanning); LAN connected=\(lan.connected); LAN probe active=\(lanProbeTask != nil); tunnel configured=\(tunnel.credential != nil); tunnel verified=\(tunnel.connected); tunnel probe active=\(tunnelProbeTask != nil); selected route=\(transport.label); phone active=\(phoneActive); CarPlay active=\(carPlayActive)")
            if wantsConnection && !pairingInProgress && !selectingDiscoveredComma {
                if mode != .lan, !bluetooth.connected, !bluetooth.connecting, !bluetooth.isScanning,
                   Date().timeIntervalSince(lastReconnect) >= bluetooth.reconnectDelay {
                    lastReconnect = Date()
                    bluetooth.reconnectSaved(pairingKey: pairingKey)
                }
                if mode != .bluetooth && !offerAudioPairing && !showAudioPairing {
                    discoverAutomaticLAN()
                    probeLocalConnection()
                    probeTunnelConnection()
                }
                guard !pairingInProgress else { continue }
                if transport.label != lastRoute { logConnection("Connection availability changed") }
                if transport.connected {
                    if offerAudioPairing { offerAudioPairing = false; startAudioPairing() }
                    if !showAudioPairing {
                        openIfReady()
                        Task { await SentryPush.shared.synchronize() }
                        if Date().timeIntervalSince(lastGalaxyMatch) > 60 && !openingGalaxy {
                            Task { await self.checkGalaxyUpdates() }
                        }
                    }
                    connectionMessage = "Connected over \(transport.label)." + (opened || assets.readyRoot != nil ? "" : " " + assets.status)
                } else if mode == .bluetooth {
                    connectionMessage = bluetooth.status
                } else {
                    connectionMessage = discovery.searching || lan.endpoint == nil
                        ? discovery.status
                        : "Comma is not reachable on the local network yet. Use the same Wi-Fi or connect comma to this iPhone’s hotspot, then search again."
                }
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }
}


enum AppPreference {
    static let startupPage = "galaxy.app.startupPage"
    static let openGalaxy = "galaxy.app.openAfterConnection"
    static let toolbarLabels = "galaxy.app.toolbarLabels"
    static let rememberDestinations = "galaxy.app.rememberDestinations"
    static let liveScreenAwake = "galaxy.app.liveScreenAwake"
}

enum AppAppearance: String {
    case system, light, dark
    static let key = "galaxy.app.appearance"
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct GalaxyRootView: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    private struct ReportCapture: Identifiable {
        let id = UUID()
        let logs: String
    }
    @State private var discordReport: ReportCapture?
    @State private var reportWasSent = false
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothTransport
    @ObservedObject var lan: LANTransport
    @ObservedObject var assets: GalaxyAssetStore
    @ObservedObject var server: LoopbackServer
    @ObservedObject var discovery: LANDiscovery
    @ObservedObject var galaxyPage: GalaxyPageDiagnostics
    @ObservedObject private var navigation: NavigationModel
    @State private var hasVisitedGalaxy = false
    @State private var appTabsExpanded = true
    @State private var showingAppTabsInGalaxy = false
    @AppStorage(GalaxyToolbar.orderKey) private var galaxyToolbarOrder = ""
    private var motionDisabled: Bool { reduceMotion || !galacticalAnimations || scenePhase != .active }
    @AppStorage("galaxy.galacticalAnimations") private var galacticalAnimations = true
    private var page: CompanionTab { model.tab == .galaxy && !model.opened ? .connections : model.tab }
    @Environment(\.colorScheme) private var systemColorScheme
    private var chromeBackground: LinearGradient {
        let dark = systemColorScheme == .dark
        let edge = Color(uiColor: StarPilotTheme.toolbarColor(dark: dark))
        if page == .galaxy {
            return LinearGradient(colors: [edge, edge], startPoint: .top, endPoint: .bottom)
        }
        let farEdge = dark ? Color(red: 0.13, green: 0.07, blue: 0.22) : Color(red: 0.87, green: 0.81, blue: 0.96)
        return LinearGradient(colors: [edge, farEdge], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var showsGalaxyPill: Bool {
        page == .galaxy && !showingAppTabsInGalaxy && !galaxyPage.barItems.isEmpty && !galaxyPage.stalled && !editorFocused
    }
    private var editorFocused: Bool { page == .galaxy && galaxyPage.landscapeEditor }
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    init(model: AppModel) {
        self.model = model; navigation = model.navigationServices.navigation; bluetooth = model.bluetooth; lan = model.lan; assets = model.assets; server = model.server; discovery = model.discovery; galaxyPage = model.galaxyPage
    }
    var body: some View {
        chrome.environment(\.reduceGalacticalMotion, motionDisabled)
            .background {
                AppPageEdgeSwipes(enabled: !editorFocused && scenePhase == .active) { fromLeft in
                    let forward = layoutDirection == .rightToLeft ? fromLeft : !fromLeft
                    let pages: [CompanionTab] = [.galaxy, .navigation, .connections].filter {
                        ($0 != .galaxy || model.opened) && ($0 != .navigation || model.navigationEnabled)
                    }
                    guard let index = pages.firstIndex(of: page) else { return }
                    let next = index + (forward ? 1 : -1)
                    if pages.indices.contains(next) { select(pages[next]) }
                }
            }
            .preferredColorScheme(appearance.scheme)
    }
    @ViewBuilder private var chrome: some View {
        if #available(iOS 27.1, *), DuoLayout.isEnabled {
            AdaptiveCompanionChrome(model: model, tab: page, select: select, showsGalaxyPill: showsGalaxyPill, showAppTabs: showAppTabs) {
                rootContent
            }
        } else {
            rootContent
        }
    }
    private var usesAdaptiveChrome: Bool {
        if #available(iOS 27.1, *) { return DuoLayout.isEnabled }
        return false
    }
    private var rootContent: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.opened, let url = server.url {
                    GalaxyWebView(url: url, requestKey: server.localSecret, diagnostics: model.galaxyPage,
                                  isActive: model.tab == .galaxy && scenePhase == .active,
                                  localWiFi: model.transport.usesLAN, bluetooth: model.transport.label == "Bluetooth") {
                        model.galaxyPage.report(server: server, connection: model.transport.label)
                    }
                        .modifier(CompanionWebSafeArea())
                        .overlay(alignment: .top) {
                            if !DuoLayout.isEnabled && !editorFocused && galaxyPage.barItems.isEmpty {
                                let dark = systemColorScheme == .dark
                                let edge = Color(uiColor: StarPilotTheme.toolbarColor(dark: dark))
                                LinearGradient(colors: [edge, edge.opacity(0)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .opacity(page == .galaxy ? 1 : 0)
                        .allowsHitTesting(page == .galaxy)
                        .accessibilityHidden(page != .galaxy)
                } else if model.opened && page == .galaxy {
                    VStack(spacing: 16) {
                        if server.error.isEmpty { ProgressView("Reconnecting Galaxy…") }
                        else { Text(server.error).multilineTextAlignment(.center) }
                        Button("Retry Galaxy") { model.recoverGalaxy(automatic: false) }.buttonStyle(.bordered)
                    }.padding(24)
                }
                if model.navigationEnabled && page == .navigation {
                    NavigationHome(connection: model.navigationServices.connection, navigation: model.navigationServices.navigation, saved: model.navigationServices.saved, selectAppTab: select, submitReport: presentReport) { select(.connections) }
                } else if page == .logs {
                    DeveloperLogsView(model: model, log: model.connectionLog, back: { select(.connections) }, submitReport: presentReport)
                } else if model.developerMode && (page == .live || page == .diagnostics) {
                    CompanionView(diagnostics: model.diagnostics)
                } else if page == .connections || !model.opened {
                    ConnectionSettingsView(model: model, returningFromGalaxy: hasVisitedGalaxy, select: select, submitReport: presentReport)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !usesAdaptiveChrome && !editorFocused && page != .navigation {
                Group {
                    if showsGalaxyPill {
                        HStack(spacing: 0) {
                            if let back = galaxyPage.barItems.first(where: { $0.id == "back" && !$0.disabled }) {
                                GalaxyPillButton(page: galaxyPage, item: back)
                            } else {
                                Button(action: showAppTabs) { Image(systemName: "chevron.backward").frame(width: 44, height: 48) }
                                    .buttonStyle(.plain).accessibilityLabel("Show app tabs")
                            }
                            ForEach(GalaxyToolbar.visible(galaxyToolbarOrder, items: galaxyPage.barItems)) { item in
                                GalaxyPillButton(page: galaxyPage, item: item)
                            }
                            GalaxyPillMenu(page: galaxyPage, model: model, compact: true, showAppTabs: showAppTabs, select: select)
                        }
                        .padding(.horizontal, 3)
                        .modifier(FloatingGalaxyGlass())
                    } else {
                        CompanionNavigationBar(tab: page, developerMode: model.developerMode,
                            navigation: model.navigationServices.navigation, expanded: $appTabsExpanded,
                            compactIconOnly: true, statusModel: model, keepsExpanded: showingAppTabsInGalaxy, select: select)
                    }
                }.padding(.horizontal, 14)
            }
        }
        .background {
            if DuoLayout.isEnabled && page == .navigation { Color.clear }
            else { chromeBackground.ignoresSafeArea() }
        }
        .onChange(of: page) { _, current in
            showingAppTabsInGalaxy = false
            if current == .galaxy { hasVisitedGalaxy = true }
        }
        .ignoresSafeArea(.container, edges: editorFocused ? .all : [])
        .statusBarHidden(editorFocused)
        .onChange(of: model.showConnections) { _, show in
            if show { select(.connections); model.showConnections = false }
        }
        .onChange(of: model.showDiagnostics) { _, show in
            if show { if model.developerMode { select(.live) }; model.showDiagnostics = false }
        }
        .onChange(of: bluetooth.connected) { _, connected in if connected { model.openIfReady() } }
        .sheet(item: $discordReport, onDismiss: {
            // Let the native sheet finish closing before animating back to Settings.
            if reportWasSent {
                reportWasSent = false
                select(.connections)
            }
        }) { capture in
            DiscordReportSheet(logs: capture.logs, captureLogs: captureReportLogs) { reportWasSent = true }
        }
        .sheet(isPresented: $model.showAudioPairing, onDismiss: { model.audioPairing.dismiss() }) {
            AudioPairingSheet(pairing: model.audioPairing) { model.showAudioPairing = false }
        }
        .alert("Bluetooth access needed", isPresented: $model.showBluetoothPermission) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(model.pairingFailure)
        }
        .task(id: scenePhase) {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--preview-navigation-planner") {
                model.navigationEnabled = true
                let nav = model.navigationServices.navigation
                let center = CLLocationCoordinate2D(latitude: 43.636, longitude: -79.388)
                nav.camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: 4000, longitudinalMeters: 4000))
                model.tab = .navigation
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-route") {
                model.developerMode = true; model.navigationEnabled = true
                let nav = model.navigationServices.navigation
                let points = [CLLocationCoordinate2D(latitude: 43.6412, longitude: -79.3894), CLLocationCoordinate2D(latitude: 43.6433, longitude: -79.3894), CLLocationCoordinate2D(latitude: 43.6433, longitude: -79.3850)]
                nav.commaPolyline = MKPolyline(coordinates: points, count: points.count)
                nav.commaPosition = points[0]
                nav.usingComma = true; nav.commaFeedReady = true; nav.navigating = true
                nav.instruction = "Turn right onto Bremner Boulevard"
                nav.commaManeuverType = "turn"; nav.commaManeuverModifier = "right"
                nav.distanceToTurn = 240; nav.remainingTime = 1920; nav.remainingDistance = 18200
                let item = MKMapItem(placemark: MKPlacemark(coordinate: points[2])); item.name = "Preview destination"
                nav.destination = NavigationPlace(item: item)
                nav.refreshPreviewPosition()
                model.tab = .navigation
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-galaxy") {
                if let fixture = ProcessInfo.processInfo.environment["GALAXY_UI_FIXTURE"] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("galaxy-layout-preview", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try fixture.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                        server.useWebRoot(directory)
                    } catch { return }
                }
                model.opened = true; model.tab = .galaxy
                return
            }
#endif
            model.setPhoneActive(scenePhase == .active)
            model.navigationServices.setEnabled(model.navigationEnabled)
            model.navigationServices.setPhoneActive(scenePhase == .active)
            if scenePhase == .active { ShareInbox.shared.activated(model: model); model.openGalaxyIfRequested(); model.recoverGalaxy(reload: false); await model.checkGalaxyUpdates() }
        }
    }
    private func presentReport() {
        model.autoOpenGalaxyPending = false
        reportWasSent = false
        discordReport = ReportCapture(logs: captureReportLogs())
    }
    private func captureReportLogs() -> String {
        [model.connectionLog.report(model: model),
                    model.galaxyPage.report(server: model.server, connection: model.transport.label),
                    model.diagnostics.diagnosticLog(),
                    "Galaxy screen updates\n" + model.assets.status].joined(separator: "\n\n")
    }
    private func showAppTabs() {
        model.autoOpenGalaxyPending = false
        appTabsExpanded = true
        showingAppTabsInGalaxy = true
    }
    private func select(_ requestedTab: CompanionTab) {
        showingAppTabsInGalaxy = false
        let tab = (requestedTab.isDeveloperPage && !model.developerMode) || (requestedTab == .navigation && !model.navigationEnabled) ? (model.opened ? CompanionTab.galaxy : .connections) : requestedTab
        if tab == .connections { appTabsExpanded = true }
        if tab != .connections { discovery.stop() }
        model.connectionLog.record("UI tab selected: \(model.tab.rawValue) → \(tab.rawValue)")
        model.tab = tab
        if tab == .galaxy { hasVisitedGalaxy = true }
        model.diagnostics.live = tab == .live
    }
    private let brandPurple = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)


}

private struct AppPageEdgeSwipes: UIViewRepresentable {
    let enabled: Bool
    let switchPage: (Bool) -> Void

    func makeUIView(context: Context) -> EdgeObserver {
        let view = EdgeObserver()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: EdgeObserver, context: Context) {
        view.switchPage = enabled ? switchPage : nil
    }

    final class EdgeObserver: UIView, UIGestureRecognizerDelegate {
        var switchPage: ((Bool) -> Void)?
        private var gestures: [UIScreenEdgePanGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            for gesture in gestures { gesture.view?.removeGestureRecognizer(gesture) }
            gestures.removeAll()
            guard let window else { return }
            for edge: UIRectEdge in [.left, .right] {
                let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(finishSwipe(_:)))
                gesture.edges = edge
                gesture.cancelsTouchesInView = false
                gesture.delegate = self
                window.addGestureRecognizer(gesture)
                gestures.append(gesture)
            }
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            switchPage != nil && window?.rootViewController?.presentedViewController == nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func finishSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let movement = gesture.translation(in: window)
            let fromLeft = gesture.edges == .left
            let distance = fromLeft ? movement.x : -movement.x
            guard distance >= 55, distance > 1.5 * abs(movement.y) else { return }
            switchPage?(fromLeft)
        }
    }
}

private struct ReduceGalacticalMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reduceGalacticalMotion: Bool {
        get { self[ReduceGalacticalMotionKey.self] }
        set { self[ReduceGalacticalMotionKey.self] = newValue }
    }
}

enum CompanionMotion {
    static let selection = Animation.spring(duration: 0.29, bounce: 0.08)
}

struct CompanionPressStyle: ButtonStyle {
    @Environment(\.reduceGalacticalMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = enabled && configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.955 : 1)
            .opacity(pressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : (pressed ? .easeOut(duration: 0.08) : CompanionMotion.selection),
                       value: pressed)
            .contentShape(Rectangle())
    }
}

private struct TabSelectionCapsule: View {
    var body: some View {
        Capsule().fill(Color(red: 0.39, green: 0.23, blue: 0.63))
            .overlay(Capsule().strokeBorder(.white.opacity(0.19), lineWidth: 0.75))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct GalaxyPillButton: View {
    @ObservedObject var page: GalaxyPageDiagnostics
    let item: GalaxyBarItem
    @AppStorage(AppPreference.toolbarLabels) private var toolbarLabels = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { page.activate(item) } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 19)
                if item.id != "back" && toolbarLabels && !typeSize.isAccessibilitySize {
                    Text(verbatim: item.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 9)
            .frame(minWidth: 44, maxWidth: item.id != "back" ? .infinity : 44, minHeight: 48)
            .foregroundStyle(item.id != "back" ? Color.primary : Color.secondary)
            .overlay(alignment: .bottom) {
                if item.selected {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 20, height: 2)
                        .padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(CompanionPressStyle()).disabled(item.disabled).accessibilityLabel(Text(verbatim: item.label))
            .accessibilityIdentifier("galaxy-pill-" + item.id)
            .accessibilityValue(item.selected ? Text("Selected") : Text(""))
            .accessibilityAddTraits(item.selected ? .isSelected : [])
    }
}

private struct AppTabsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "square.grid.2x2").frame(width: 44, height: 44)
        }.accessibilityLabel("Show app tabs").accessibilityIdentifier("galaxy-app-tabs")
    }
}

private struct GalaxyPillMenu: UIViewRepresentable {
    let page: GalaxyPageDiagnostics
    let model: AppModel
    let select: (CompanionTab) -> Void
    @Environment(\.locale) private var locale

    let showAppTabs: (() -> Void)?
    @AppStorage(GalaxyToolbar.orderKey) private var toolbarOrder = ""
    let compact: Bool

    init(page: GalaxyPageDiagnostics, model: AppModel, compact: Bool = false, showAppTabs: (() -> Void)? = nil, select: @escaping (CompanionTab) -> Void) {
        self.page = page
        self.model = model
        self.showAppTabs = showAppTabs
        self.compact = compact
        self.select = select
    }

    final class Coordinator {
        var menu: GalaxyPillMenu
        init(_ menu: GalaxyPillMenu) { self.menu = menu }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let symbol = compact ? "ellipsis" : "ellipsis.circle"
        let configuration = compact ? UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold) : UIImage.SymbolConfiguration(textStyle: .title3)
        button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        if compact { button.tintColor = .secondaryLabel }
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "galaxy-pill-options"
        // Resolve the rows once per opening so live telemetry cannot rebuild a
        // presented menu while the user scrolls it.
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            completion(coordinator.menu.sections())
        }])
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.menu = self
        button.accessibilityLabel = String(localized: "Galaxy and app options", locale: locale)
    }

    private func sections() -> [UIMenuElement] {
        var appActions: [UIAction] = []
        if let showAppTabs {
            appActions.append(UIAction(title: String(localized: "Show app tabs", locale: locale), image: UIImage(systemName: "square.grid.2x2")) { _ in showAppTabs() })
        }
        if model.navigationEnabled {
            appActions.append(UIAction(title: String(localized: "Navigation", locale: locale), image: UIImage(systemName: CompanionTab.navigation.icon)) { _ in
                if model.navigationEnabled { select(.navigation) }
            })
        }
        appActions.append(UIAction(title: String(localized: "Settings", locale: locale), image: UIImage(systemName: CompanionTab.connections.icon)) { _ in select(.connections) })

        var galaxyActions: [UIAction] = []
        if !page.deviceStatus.isEmpty {
            galaxyActions.append(UIAction(title: page.deviceStatus, attributes: .disabled) { _ in })
        }
        let visible = GalaxyToolbar.visible(toolbarOrder, items: page.barItems)
        for item in page.barItems where !compact || (item.id != "back" && !visible.contains(item)) {
            galaxyActions.append(UIAction(title: item.label, image: UIImage(systemName: item.icon), attributes: item.disabled ? .disabled : []) { _ in
                if let current = page.barItems.first(where: { $0.id == item.id }) { page.activate(current) }
            })
        }
        return [
            UIMenu(title: String(localized: "StarPilot BT", locale: locale), options: .displayInline, children: appActions),
            UIMenu(title: String(localized: "Galaxy", locale: locale), options: .displayInline, children: galaxyActions)
        ]
    }
}

struct CompanionNavigationBar: View {
    @Namespace private var selection
    let tab: CompanionTab
    let developerMode: Bool
    @ObservedObject var navigation: NavigationModel
    @Binding var expanded: Bool
    var compactIconOnly = false
    var statusModel: AppModel? = nil
    var keepsExpanded = false
    let select: (CompanionTab) -> Void
    @Environment(\.reduceGalacticalMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var idleKey: String { "\(tab.rawValue)-\(expanded)-\(navigation.navigating)-\(voiceOver)" }
    var body: some View {
        GeometryReader { geometry in
            // Keep both content trees alive at their natural sizes. Only the glass
            // envelope and transforms animate; labels never squeeze and reflow.
            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    ForEach(statusModel?.navigationEnabled == false ? [CompanionTab.galaxy, .connections] : [CompanionTab.galaxy, .navigation, .connections]) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 15, weight: .semibold))
                                Text(LocalizedStringKey(item.rawValue)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            }.frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle((tab == item || (tab == .logs && item == .connections)) ? Color.white : Color.primary.opacity(0.7))
                                .background {
                                    if tab == item || (tab == .logs && item == .connections) {
                                        TabSelectionCapsule()
                                            .matchedGeometryEffect(id: "activeTab", in: selection)
                                    }
                                }
                        }.buttonStyle(CompanionPressStyle()).accessibilityIdentifier("main-tab-" + item.rawValue)
                            .accessibilityAddTraits((tab == item || (tab == .logs && item == .connections)) ? .isSelected : [])
                    }

                }.animation(reduceMotion ? nil : CompanionMotion.selection, value: tab)
                    .padding(3)
                    .padding(.trailing, statusModel == nil ? 0 : 32)
                    .frame(width: geometry.size.width)
                    .offset(x: expanded || reduceMotion ? 0 : -8)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded).accessibilityHidden(!expanded)
                Button { setExpanded(true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon).foregroundStyle(StarPilotTheme.accent)
                        if !compactIconOnly { Text(tab.rawValue).font(.system(size: 13, weight: .semibold)) }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.frame(width: compactWidth, height: 46)
                }.buttonStyle(.plain).accessibilityLabel("Show app tabs").accessibilityIdentifier("expand-app-tabs")
                    .opacity(expanded ? 0 : 1)
                    .scaleEffect(expanded ? 0.8 : 1, anchor: .leading)
                    .allowsHitTesting(!expanded).accessibilityHidden(expanded)
            }
            .frame(width: expanded ? geometry.size.width : compactWidth, height: 46, alignment: .leading)
            .clipped()
            .modifier(FloatingGalaxyGlass())
            .frame(width: geometry.size.width, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let statusModel {
                    CompactConnectionStatus(model: statusModel, compact: expanded) { select(.connections) }
                        .padding(.trailing, expanded ? 5 : 0)
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 46)
        .onChange(of: tab) { _, newTab in if newTab == .connections { setExpanded(true) } }
        .task(id: idleKey) {
            guard expanded, !keepsExpanded, !voiceOver, tab == .galaxy || tab == .navigation else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            setExpanded(false)
        }
    }
    private var compactWidth: CGFloat { compactIconOnly ? 56 : 168 }
    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : CompanionMotion.selection) { expanded = value }
    }
}

/// Displays the selected verified transport, not Wi-Fi availability or a saved address.
struct CompactConnectionStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bluetooth: BluetoothTransport
    @ObservedObject private var lan: LANTransport
    @ObservedObject private var tunnel: TunnelTransport
    let openSettings: () -> Void
    var compact: Bool
    var nativeToolbar: Bool

    init(model: AppModel, compact: Bool = false, nativeToolbar: Bool = false, openSettings: @escaping () -> Void) {
        self.model = model
        self.compact = compact
        self.nativeToolbar = nativeToolbar
        bluetooth = model.bluetooth
        lan = model.lan
        tunnel = model.tunnel
        self.openSettings = openSettings
    }

    private var label: String {
        switch model.transport.selectedRoute {
        case .bluetooth: return "Bluetooth"
        case .lan: return lan.endpoint?.host ?? "Local Wi-Fi"
        // Tunnel links may contain private access codes. Never display the link here.
        case .tunnel: return "Tunnel"
        case nil: return bluetooth.connecting || bluetooth.isScanning ? "Connecting…" : "Disconnected"
        }
    }
    private var tint: Color {
        model.transport.connected ? .green : bluetooth.connecting || bluetooth.isScanning ? .orange : .secondary
    }
    var body: some View {
        if nativeToolbar {
            Button(action: openSettings) {
                Label("Connection: " + label, systemImage: "circle.fill")
            }
            .tint(tint)
            .accessibilityLabel("Connection settings")
            .accessibilityValue(model.transport.connected ? "Connected via " + label : label)
            .accessibilityIdentifier("bluetooth-connection-status")
        } else {
            Button(action: openSettings) {
                HStack(spacing: compact ? 0 : 7) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(label).font(.system(size: 13, weight: .medium))
                        .monospacedDigit().lineLimit(1).truncationMode(.middle)
                        .frame(width: compact ? 0 : nil).opacity(compact ? 0 : 1)
                        .clipped()
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).frame(height: 44)
                .background {
                    Capsule().fill(.regularMaterial).opacity(compact ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection settings")
            .accessibilityValue(model.transport.connected ? "Connected via " + label : label)
            .accessibilityIdentifier("bluetooth-connection-status")
        }
    }
}

struct FloatingGalaxyGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = Capsule()
        Group {
            if reduceTransparency {
                content.background(Color(uiColor: .secondarySystemBackground), in: shape)
            } else if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(.purple.opacity(0.08)).interactive(), in: shape)
            } else {
                content.background(.thinMaterial, in: shape)
            }
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(scheme == .dark ? 0.6 : 0.85), location: 0),
                    .init(color: .white.opacity(0.12), location: 0.35),
                    .init(color: .purple.opacity(0.19), location: 0.7),
                    .init(color: .white.opacity(0.55), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.25
            ).allowsHitTesting(false).accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.10), radius: 6, y: 2)
    }
}

@MainActor
final class ConnectionEventLog: ObservableObject {
    private var storage = Array(repeating: "", count: 12000)
    // Keep failure evidence even when successful polling rolls out the main timeline.
    private var failureStorage = Array(repeating: "", count: 256)
    private var nextFailure = 0
    private var failureCount = 0
    private var totalFailures = 0
    var failureEvents: [String] {
        let start = failureCount == failureStorage.count ? nextFailure : 0
        return (0..<failureCount).map { failureStorage[(start + $0) % failureStorage.count] }
    }
    private static let failurePattern = try! NSRegularExpression(pattern:
        #"(?i:failed|rejected|blocked|terminated|timeout|timed out|disconnected|replay blocked|exhausted|no addresses|0 result\(s\)|HTTP [45][0-9]{2})"#)
    private var nextEvent = 0
    private var retained = 0
    private var sequence = 0
    private var repeats = 0
    private let uptime = ProcessInfo.processInfo.systemUptime
    var events: [String] {
        let start = retained == storage.count ? nextEvent : 0
        return (0..<retained).map { storage[(start + $0) % storage.count] }
    }
    @Published var section = "Connections"
    @Published var detail = ""
    @Published var copied = false
    private var lastEvent = ""
    private let started = Date()
    private var dropped = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    // Error descriptions can contain private tunnel URLs or key material.
    private static let privateValues = try! NSRegularExpression(pattern:
        #"https?://[^\s]+|\b[0-9a-fA-F]{64}\b|(?i:bearer)\s+[^\s]+"#)
    private static func redact(_ text: String) -> String {
        privateValues.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
    }
    private var stateEvents: [String: String] = [:]
    func recordState(_ key: String, _ event: String) {
        guard stateEvents[key] != event else { return }
        if stateEvents.count >= 32 && stateEvents[key] == nil { stateEvents.removeAll(keepingCapacity: true) }
        stateEvents[key] = event
        record(event)
    }
    // No published changes or disk/network work on the connection callback path.
    func record(_ event: String) {
        let redacted = Self.redact(event)
        let bounded = redacted.count > 2000 ? String(redacted.prefix(2000)) + " [event shortened]" : redacted
        guard bounded != lastEvent else { repeats += 1; return }
        if repeats > 0 { append("Previous event repeated \(repeats) additional times"); repeats = 0 }
        lastEvent = bounded
        append(bounded)
    }
    private func append(_ event: String) {
        sequence += 1
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - uptime)
        storage[nextEvent] = "\(formatter.string(from: Date())) #\(sequence) +\(elapsed)s \(event)"
        if Self.failurePattern.firstMatch(in: event, range: NSRange(event.startIndex..., in: event)) != nil {
            failureStorage[nextFailure] = storage[nextEvent]
            nextFailure = (nextFailure + 1) % failureStorage.count
            failureCount = min(failureCount + 1, failureStorage.count)
            totalFailures += 1
        }
        nextEvent = (nextEvent + 1) % storage.count
        if retained == storage.count { dropped += 1 } else { retained += 1 }
    }
    func clear() {
        storage = Array(repeating: "", count: 12000)
        failureStorage = Array(repeating: "", count: 256)
        nextFailure = 0; failureCount = 0; totalFailures = 0
        nextEvent = 0; retained = 0; dropped = 0; repeats = 0
        lastEvent = ""; stateEvents.removeAll(keepingCapacity: true); detail = ""; copied = false
    }
    func report(model: AppModel, eventLimit: Int? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot BT connection diagnostics
        Connection diagnostics revision: 6 (setup stages and route state)
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        Build distribution: \(model.buildDistribution)
        iOS: \(UIDevice.current.systemVersion)
        OS build: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Phone class: \(UIDevice.current.model); low power mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled); thermal state=\(ProcessInfo.processInfo.thermalState.rawValue)
        Local timezone: \(TimeZone.current.identifier); UTC offset seconds=\(TimeZone.current.secondsFromGMT())
        \(model.connectionControllerDiagnostics)
        Network path: \(model.networkPathDiagnostics)
        Mode: \(model.mode.title)
        Selected route: \(model.connectionStatusLabel)
        Available transports: local Wi-Fi=\(model.lan.connected); Tunnel=\(model.tunnel.connected); Bluetooth=\(model.bluetooth.connected)
        Tunnel verified: \(model.tunnel.connected)
        Tunnel status: \(model.tunnel.status)
        Tunnel detail: \(model.tunnel.diagnosticSummary)
        Connection order: \(model.connectionPriority.map(\.title).joined(separator: " → "))
        \(model.commaSoftwareDiagnostics)
        Saved comma identity present: \(model.lan.expectedDeviceID != nil)
        LAN verified: \(model.lan.connected)
        LAN endpoint: \(model.lan.endpoint?.host ?? "none"):8082
        LAN status: \(model.lan.status)
        Phone private IPv4 interfaces: \(LANDiscovery.privateInterfaceDiagnostics())
        Bluetooth verified: \(model.bluetooth.connected)
        Bluetooth app key saved: \(!model.pairingKey.isEmpty)
        Bluetooth detail: \(model.bluetooth.diagnosticSummary)
        Log session started: \(formatter.string(from: started)); retained: \(retained); older events dropped: \(dropped); pending repeated events: \(repeats)
        Current screen: \(model.tab.rawValue)
        GPS sharing: \(model.phoneLocation.sharing); \(model.phoneLocation.diagnosticSummary)
        \(model.navigationServices.navigation.diagnosticSummary)
        Bluetooth permission: \(CBManager.authorization)
        Discovery: searching=\(model.discovery.searching); results=\(model.discovery.devices.count)
        Discovery status: \(model.discovery.status)
        Discovery detail: \(model.discovery.diagnosticSummary)
        Local Network permission: iOS does not expose a direct status; see discovery errors and LAN verification above.
        LAN pairing setup saved: \(model.hasLANPairingSetup)
        Pairing active: \(model.pairingInProgress); setup busy: \(model.connectionSetupBusy)
        Last pairing failure: \(model.pairingFailure.isEmpty ? "none" : model.pairingFailure)
        Current connection message: \(model.connectionMessage)
        Navigation enabled: \(model.navigationEnabled)
        Retained failure events (may also appear in the timeline; retained=\(failureCount); older failures dropped=\(max(0, totalFailures - failureCount))):
        \(failureEvents.suffix(eventLimit ?? failureCount).joined(separator: "\n"))
        Recent connection events:
        \(events.suffix(eventLimit ?? retained).joined(separator: "\n"))
        """
    }
}

// A single-entry ZIP stores the full UTF-8 report without a third-party dependency.
enum DiagnosticArchive {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in
            (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320)
        }
    }

    static func zip(_ text: String) -> Data {
        let name = Data("diagnostics.txt".utf8)
        let contents = Data(text.utf8)
        let size = UInt32(contents.count)
        let crc = contents.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        } ^ UInt32.max
        var archive = Data()
        func word(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { archive.append(contentsOf: $0) }
        }
        func long(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { archive.append(contentsOf: $0) }
        }
        func entryFields() {
            word(20) // ZIP version needed
            word(0) // flags
            word(0) // stored data
            word(0) // time
            word(33) // 1980-01-01
            long(crc)
            long(size)
            long(size)
            word(UInt16(name.count))
            word(0) // extra field length
        }

        long(0x04034b50)
        entryFields()
        archive.append(name)
        archive.append(contents)
        let directoryOffset = UInt32(archive.count)

        long(0x02014b50)
        word(20)
        entryFields()
        word(0) // comment length
        word(0) // disk number
        word(0) // internal attributes
        long(0) // external attributes
        long(0) // local header offset
        archive.append(name)
        let directorySize = UInt32(archive.count) - directoryOffset

        long(0x06054b50)
        word(0)
        word(0)
        word(1)
        word(1)
        long(directorySize)
        long(directoryOffset)
        word(0)
        return archive
    }
}

private struct DeveloperLogsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: ConnectionEventLog
    let back: () -> Void
    let submitReport: () -> Void
    @State private var sharedReport: GalaxyDownloadedFile?
    @State private var reportDirectory: URL?
    @State private var exportStatus = ""
    @State private var exporting = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.48, blue: 0.96) : Color(red: 0.45, green: 0.26, blue: 0.73) }
    private var panel: Color { colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.88, green: 0.83, blue: 0.95) }
    private var background: Color { colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.93, green: 0.90, blue: 0.98) }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.65, blue: 0.77) : Color(red: 0.36, green: 0.29, blue: 0.46) }
    private func allReports() -> String {
        [log.report(model: model), model.galaxyPage.report(server: model.server, connection: model.transport.label), model.diagnostics.diagnosticLog(), "Galaxy screen updates\n" + model.assets.status].joined(separator: "\n\n")
    }
    private func selectedReport() -> String {
        switch log.section {
        case "Galaxy": return model.galaxyPage.report(server: model.server, connection: model.transport.label)
        case "Live View": return model.diagnostics.diagnosticLog()
        default: return log.report(model: model)
        }
    }
    private func previewReport() -> String {
        log.section == "Connections" ? log.report(model: model, eventLimit: 150) : selectedReport()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Logs & support").font(.largeTitle.bold()).frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        Button(action: back) { Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("Back to Settings")
                    }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Need a hand?", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.headline).foregroundStyle(accent)
                    Text("Report a problem through Discord to keep your logs and support replies together.")
                        .font(.subheadline).foregroundStyle(muted)
                    Button {
                        submitReport()
                    } label: {
                        Label("Report a problem on Discord", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(.white).background(accent, in: Capsule())
                    }.buttonStyle(.plain)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        DisclosureGroup("View diagnostic logs") {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Report", selection: $log.section) {
                                    ForEach(["Connections", "Galaxy", "Live View"], id: \.self) { Text($0).tag($0) }
                                }.pickerStyle(.segmented)
                                HStack {
                                    Button(log.copied ? "Copied" : "Copy selected", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = selectedReport(); log.copied = true
                                    }
                                    Spacer()
                                    Button("Refresh", systemImage: "arrow.clockwise") { log.detail = previewReport(); log.copied = false }
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Button("Copy all diagnostics", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = allReports(); log.copied = true
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Text("Preview shows the latest 150 connection events. Copy or share includes the full retained log.")
                                .font(.caption).foregroundStyle(.secondary)
                                Text(log.detail)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                                Button("Clear connection history") { log.clear(); log.detail = previewReport() }
                                .font(.caption).foregroundStyle(muted)
                            }
                        }.font(.subheadline).tint(muted)
                        Divider()
                        Button(exporting ? "Preparing report…" : "Export logs (.zip)") {
                            guard !exporting else { return }
                            exporting = true; exportStatus = ""
                            let report = allReports()
                            Task {
                                do {
                                    let url = try await Task.detached(priority: .utility) {
                                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                        do {
                                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                            let name = "StarPilot-diagnostics-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".zip"
                                            let url = directory.appendingPathComponent(name)
                                            try DiagnosticArchive.zip(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                            return url
                                        } catch {
                                            try? FileManager.default.removeItem(at: directory)
                                            throw error
                                        }
                                    }.value
                                    reportDirectory = url.deletingLastPathComponent()
                                    sharedReport = GalaxyDownloadedFile(url: url)
                                } catch { exportStatus = "Couldn’t prepare diagnostics. Try again or copy the report." }
                                exporting = false
                            }
                        }.buttonStyle(.plain).font(.footnote).foregroundStyle(muted)
                            .frame(minHeight: 44, alignment: .leading).disabled(exporting).accessibilityIdentifier("save-diagnostics-zip")
                        if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
                        Text("For manual troubleshooting when needed.")
                            .font(.caption).foregroundStyle(muted)
                    }.padding(.top, 12)
                } label: {
                    Text("Troubleshooting").font(.subheadline).foregroundStyle(muted)
                }.tint(muted)
            }.padding(20)
        }.background(background.ignoresSafeArea())
            .sheet(item: $sharedReport, onDismiss: {
                if let directory = reportDirectory { try? FileManager.default.removeItem(at: directory) }
                reportDirectory = nil
            }) { file in
                GalaxyFileShareSheet(url: file.url) { sharedReport = nil }
            }
            .task {
                while !Task.isCancelled {
                    let report = previewReport()
                    if report != log.detail { log.detail = report }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onChange(of: log.section) { _, _ in log.detail = previewReport(); log.copied = false }
    }
}

/// The system owns placement and safe-area reservation, including Duo's side rail.
@available(iOS 27.1, *)
private struct AdaptiveCompanionChrome<Content: View>: View {
    @ObservedObject var model: AppModel
    let tab: CompanionTab
    let select: (CompanionTab) -> Void
    let showsGalaxyPill: Bool
    let showAppTabs: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack {
            AdaptiveCompanionLayout(model: model, tab: tab, select: select, showsGalaxyPill: showsGalaxyPill, showAppTabs: showAppTabs, content: content)
        }
    }
}

private struct CompanionWebSafeArea: ViewModifier {
    @Environment(\.companionVerticalBar) private var verticalBar
    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: verticalBar ? [.top, .bottom] : .bottom)
    }
}

private struct CompanionVerticalBarKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var companionVerticalBar: Bool {
        get { self[CompanionVerticalBarKey.self] }
        set { self[CompanionVerticalBarKey.self] = newValue }
    }
}

@available(iOS 27.1, *)
private struct AdaptiveCompanionLayout<Content: View>: View {
    @ObservedObject private var galaxyPage = AppModel.shared.galaxyPage
    @AppStorage(AppPreference.toolbarLabels) private var toolbarLabels = true
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ObservedObject var model: AppModel
    let tab: CompanionTab
    let select: (CompanionTab) -> Void
    let showsGalaxyPill: Bool
    let showAppTabs: () -> Void
    @ViewBuilder var content: () -> Content
    private var tabs: [CompanionTab] {
        model.navigationEnabled ? [.galaxy, .navigation, .connections] : [.galaxy, .connections]
    }
    var body: some View {
        content()
            .environment(\.companionVerticalBar, verticalEdge != nil)
            .toolbar {
                if showsGalaxyPill {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        AppTabsButton(action: showAppTabs)
                        ForEach(galaxyPage.barItems.filter { $0.id == "back" || $0.primary }
                            .sorted { $0.id == "back" && $1.id != "back" }) { item in
                            Button { galaxyPage.activate(item) } label: {
                                let label = Label { Text(verbatim: item.label) } icon: { Image(systemName: item.icon) }
                                if toolbarLabels && item.primary && verticalEdge == nil {
                                    label.labelStyle(.titleAndIcon)
                                } else {
                                    label.labelStyle(.iconOnly)
                                }
                            }
                            .tint(item.selected ? Color.purple : Color.primary)
                            .disabled(item.disabled)
                            .accessibilityIdentifier("galaxy-pill-" + item.id)
                            .accessibilityValue(item.selected ? Text("Selected") : Text(""))
                            .accessibilityAddTraits(item.selected ? .isSelected : [])
                        }
                        GalaxyPillMenu(page: galaxyPage, model: model, select: select)
                    }.axisBehavior(.verticalPreferred)
                } else {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        ForEach(tabs) { item in
                            let selected = tab == item || (tab == .logs && item == .connections)
                            Button { select(item) } label: {
                                Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                            }
                            .tint(selected ? .purple : .primary)
                            .accessibilityLabel(Text(LocalizedStringKey(item.rawValue)))
                            .accessibilityIdentifier("main-tab-" + item.rawValue)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.axisBehavior(.verticalPreferred)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AdaptiveConnectionStatus(model: model, openSettings: { select(.connections) })
                }.axisBehavior(.verticalPreferred)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .navigationBar)
            .toolbarVerticalBehavior(.automatic)
    }

}

@available(iOS 27.1, *)
private struct AdaptiveConnectionStatus: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @State private var showingConnection = false
    var body: some View {
        CompactConnectionStatus(model: model, nativeToolbar: true) {
            showingConnection = true
        }
        .popover(isPresented: $showingConnection) {
            VStack(spacing: 12) {
                Text("Connection").font(.headline)
                CompactConnectionStatus(model: model) {
                    showingConnection = false
                    openSettings()
                }
                .fixedSize(horizontal: true, vertical: false)
                Button("Connection settings") {
                    showingConnection = false
                    openSettings()
                }
            }
            .padding(20)
            .fixedSize()
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Fail closed: only the identified Duo hardware/simulator uses the experimental layout.
enum DuoLayout {
    static let isEnabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        #else
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return identifier == "iPhone19,4"
        #endif
    }()
}
