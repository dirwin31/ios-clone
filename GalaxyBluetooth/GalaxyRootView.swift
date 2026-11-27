import SwiftUI
import QuartzCore
import CoreImage
import Network
import MapKit
import CoreBluetooth
import StoreKit

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
    @AppStorage(AppPreference.expandedGalaxyView) private var expandedGalaxyView = true
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
        expandedGalaxyView && page == .galaxy && !showingAppTabsInGalaxy && !galaxyPage.barItems.isEmpty && !galaxyPage.stalled && !editorFocused
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
                                  expandedView: expandedGalaxyView, localWiFi: model.transport.usesLAN, bluetooth: model.transport.label == "Bluetooth") {
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
    private func captureReportLogs() -> String { model.supportReport() }
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
