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
    func setPhoneActive(_ active: Bool) { connectionLog.record("Lifecycle: phone active=\(active); tab=\(tab.rawValue); navigation=\(navigationActive)"); if !active { connectionLog.persist(reason: "left foreground") }; phoneActive = active; if !active { automaticLAN?.cancel(); firstConnection?.cancel(); firstConnection = nil }; diagnostics.phoneActive = active; discovery.setActive(active); updateMonitoring() }
    func supportReport() -> String {
        ConnectionEventLog.redact([connectionLog.report(model: self),
                                   galaxyPage.report(server: server, connection: transport.label),
                                   diagnostics.diagnosticLog(),
                                   "Galaxy screen updates\n" + assets.status].joined(separator: "\n\n"))
    }
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
    private var lastHealthyLANProbe = Date.distantPast
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
    @Published var connectionMessage = String(localized: "Choose a connection, or use Automatic to follow your connection priority.")
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
        connectionMessage = String(localized: "Preparing Bluetooth setup over Local Wi-Fi…")
        pairingTask = Task { @MainActor in
            defer { pairingInProgress = false; pairingTask = nil }
            do {
                // Bluetooth-only invalidates the normal LAN session. Use a separate, identity-checked
                // connection just for opening the pairing window; do not change the selected route.
                let pairingLAN = discoveryTransport(for: address, context: "Bluetooth pairing via LAN")
                pairingLAN.bind(to: lan.expectedDeviceID)
                if !lan.connected, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    connectionMessage = String(localized: "Checking comma over Local Wi-Fi before Bluetooth pairing…")
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
                connectionMessage = String(localized: "Opened comma’s pairing window over Local Wi-Fi. Looking for comma…")
                connectionLog.record("Phone pairing window opened over verified LAN")
                try Task.checkCancellation()
                importClaim(try await claimer.claim(name: UIDevice.current.name, expectedAdapterAddress: expectedAdapter))
            }
            catch is CancellationError { connectionMessage = String(localized: "Pairing cancelled.") }
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
        connectionMessage = String(localized: "Paired. Connecting to comma…")
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
                if reason == "Phone pairing started" { self.connectionMessage = String(localized: "Starting Bluetooth…") }
                else if reason == "Phone pairing found comma; connecting" { self.connectionMessage = String(localized: "Connecting to comma…") }
                else if reason == "Phone pairing connected; discovering service" { self.connectionMessage = String(localized: "Checking Bluetooth service…") }
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
            connectionMessage = String(localized: "Checking your comma…")
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
        connectionMessage = String(localized: "Disconnected.")
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
        connectionMessage = String(localized: "Looking for your comma. After Local Wi-Fi connects, choose Bluetooth to set up pairing again.")
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
                connectionMessage = String(localized: "Couldn’t connect to \(device.address): \(candidate.status)")
                discoveryCheck("Selected comma \(device.address) rejected: \(candidate.status)")
                return false
            }
            guard !Task.isCancelled, lan.generation == originalGeneration, mode == originalMode, phoneActive else {
                connectionMessage = String(localized: "Connection changed. Select the comma again.")
                discoveryCheck("Selected comma check interrupted after verification; connection or app state changed")
                return false
            }
            lan.bind(to: candidate.verifiedDeviceID)
            pairingResetNeeded = false
            UserDefaults.standard.set(candidate.verifiedDeviceID, forKey: "galaxy.comma.identity")
            address = device.address
            connect()
            guard await lan.probe() else {
                connectionMessage = String(localized: "Couldn’t connect to \(device.address): \(lan.status)")
                discoveryCheck("Selected comma \(device.address) failed final verification: \(lan.status)")
                return false
            }
            openIfReady()
            discoveryCheck("Discovered comma selected; LAN verification passed")
            return true
        } catch {
            connectionMessage = String(localized: "Couldn’t connect to the discovered comma. Try again or enter its IP.")
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
        guard !selectingDiscoveredComma, lanProbeTask == nil,
              !lan.connected || Date().timeIntervalSince(lastHealthyLANProbe) >= 10 else { return }
        lanProbeTask = Task { @MainActor in
            defer { self.lanProbeTask = nil }
            await self.learnAddress()
            guard !Task.isCancelled, self.wantsConnection, self.mode != .bluetooth else { return }
            if self.lan.endpoint == nil, !self.address.isEmpty {
                do { try self.lan.configure(address: self.address) }
                catch { self.connectionMessage = error.localizedDescription }
            }
            _ = await self.lan.probe()
            if !Task.isCancelled, self.lan.connected { self.lastHealthyLANProbe = Date(); self.discovery.stop() }
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
                    connectionMessage = String(localized: "Connected over \(transport.label).") + (opened || assets.readyRoot != nil ? "" : " " + assets.status)
                } else if mode == .bluetooth {
                    connectionMessage = bluetooth.status
                } else {
                    connectionMessage = discovery.searching || lan.endpoint == nil
                        ? discovery.status
                        : String(localized: "Comma is not reachable on the local network yet. Use the same Wi-Fi or connect comma to this iPhone’s hotspot, then search again.")
                }
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }
}


enum AppPreference {
    static let startupPage = "galaxy.app.startupPage"
    static let openGalaxy = "galaxy.app.openAfterConnection"
    static let expandedGalaxyView = "galaxy.app.expandedGalaxyView"
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
