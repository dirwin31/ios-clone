import SwiftUI
import QuartzCore
import CoreImage
import Network
import MapKit
import CoreBluetooth
import StoreKit

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

struct GalaxyPillButton: View {
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

struct GalaxyPillMenu: UIViewRepresentable {
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


/// The system owns placement and safe-area reservation, including Duo's side rail.
@available(iOS 27.1, *)
struct AdaptiveCompanionChrome<Content: View>: View {
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

struct CompanionWebSafeArea: ViewModifier {
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
