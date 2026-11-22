import SwiftUI
import MapKit

private struct NavigationMapLayer: View {
    @ObservedObject var navigation: NavigationModel
    let tripFrame: CGRect
    let bottomInset: CGFloat
    @AppStorage(NavigationMapPreference.enabledKey) private var useMapbox = true
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""

    var body: some View {
        Group {
            if useMapbox && token.hasPrefix("pk.") {
                MapboxDriveMap(navigation: navigation, token: token, bottomInset: bottomInset, tripFrame: tripFrame)
                    .id(token)
            } else if navigation.navigating && navigation.usingComma {
                CommaFollowingMap(navigation: navigation, bottomInset: bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                Map(position: $navigation.camera) {
                    UserAnnotation()
                    if let start = navigation.plannedStart {
                        Marker(start.name, systemImage: "flag.fill", coordinate: start.coordinate).tint(StarPilotTheme.accent)
                    }
                    ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                        MapPolyline(route.polyline).stroke(index == navigation.selectedRoute ? Color(uiColor: StarPilotTheme.routePurple) : Color.gray.opacity(0.5),
                            style: StrokeStyle(lineWidth: index == navigation.selectedRoute ? 8 : 5, lineCap: .round))
                    }
                    if let destination = navigation.destination {
                        Marker(destination.name, coordinate: destination.coordinate).tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapCompass(); MapScaleView() }
                .onChange(of: navigation.camera.positionedByUser) { _, moved in
                    if moved { navigation.followsUser = false }
                }
            }
        }
    }
}

private enum PlacePanelLevel {
    case collapsed, standard, expanded

    func dragGesture(level: Binding<Self>, offset: GestureState<CGFloat>) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating(offset) { value, state, _ in
                if abs(value.translation.height) > abs(value.translation.width) { state = value.translation.height }
            }
            .onEnded { value in
                let dy = value.translation.height
                guard abs(dy) >= 12, abs(dy) > abs(value.translation.width) else { return }
                let next: Self
                if dy > 0 { next = .collapsed }
                else { next = level.wrappedValue == .collapsed ? .standard : .expanded }
                withAnimation(.snappy) { level.wrappedValue = next }
            }
    }
}

private struct PlacePanelContentTop: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PlacePanelScroll<Content: View>: View {
    @Binding var level: PlacePanelLevel
    @State private var contentTop: CGFloat = 0
    @State private var beganAtTop: Bool?
    @Namespace private var scrollSpace
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content().background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PlacePanelContentTop.self,
                                           value: geometry.frame(in: .named(scrollSpace)).minY)
                }
            }
        }
        .coordinateSpace(name: scrollSpace)
        .onPreferenceChange(PlacePanelContentTop.self) { contentTop = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { _ in if beganAtTop == nil { beganAtTop = contentTop >= -1 } }
            .onEnded { value in
                defer { beganAtTop = nil }
                let dy = value.translation.height
                if beganAtTop == true, dy > 36, dy > abs(value.translation.width) {
                    withAnimation(.snappy) { level = .collapsed }
                }
            })
    }
}

private struct PlacePanelHandle: View {
    @Binding var level: PlacePanelLevel
    let drag: GestureState<CGFloat>

    var body: some View {
        Capsule().fill(.secondary.opacity(0.45)).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
            .gesture(level.dragGesture(level: $level, offset: drag).exclusively(before: TapGesture().onEnded {
                withAnimation(.snappy) { level = level == .collapsed ? .standard : .collapsed }
            }))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(level == .collapsed ? "Expand place panel" : "Collapse place panel")
            .accessibilityIdentifier("place-panel-handle")
            .accessibilityAction {
                withAnimation(.snappy) { level = level == .collapsed ? .standard : .collapsed }
            }
    }
}

private struct StandardNavigationHome: View {
    @AppStorage(NavigationDistanceUnits.key) private var distanceUnits = NavigationDistanceUnits.system
    @ObservedObject var connection: CommaConnection
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    @ObservedObject private var bluetooth: BluetoothTransport
    @Environment(\.reduceGalacticalMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var submitReport: () -> Void
    var openSettings: () -> Void
    var selectAppTab: (CompanionTab) -> Void
    @State private var searchPurpose: PlaceSearchPurpose?
    @State private var showLibrary = false
    @State private var tripFrame = CGRect.zero
    @State private var panelLevel: PlacePanelLevel = .standard
    @GestureState private var panelDrag: CGFloat = 0
    private var expanded: Bool { panelLevel == .expanded }
    @State private var appTabsExpanded = true
    init(connection: CommaConnection, navigation: NavigationModel, saved: SavedPlacesStore, selectAppTab: @escaping (CompanionTab) -> Void, submitReport: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.submitReport = submitReport
        self.openSettings = openSettings
        self.selectAppTab = selectAppTab
        self.connection = connection; self.navigation = navigation; self.saved = saved
        bluetooth = connection.bluetooth
    }
    var body: some View {
        GeometryReader { geometry in
            NavigationMapLayer(navigation: navigation, tripFrame: tripFrame, bottomInset: tripFrame.height)
            .overlay(alignment: .top) { mapHeader.padding(12) }
            .modifier(PlacePanelLayout(overlaid: navigation.navigating && navigation.usingComma) {
                VStack(spacing: 0) {
                    if !navigation.navigating {
                        PlacePanelHandle(level: $panelLevel, drag: $panelDrag)
                    }
                    if !navigation.error.isEmpty {
                        Text(LocalizedStringKey(navigation.error)).font(.callout).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                            .accessibilityIdentifier("navigation-error-banner")
                    }
                    if !navigation.notice.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(LocalizedStringKey(navigation.notice)).font(.callout)
                            Spacer(minLength: 0)
                            Button { navigation.notice = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Dismiss navigation message")
                        }.foregroundStyle(StarPilotTheme.accent)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    if !navigation.navigating {
                        searchBar.padding(.horizontal, 20).padding(.bottom, 12)
                            .simultaneousGesture(panelLevel.dragGesture(level: $panelLevel, offset: $panelDrag))
                    }
                    if navigation.navigating {
                        VStack(alignment: .leading, spacing: 12) {
                            tripPanel
                            messages
                        }.padding(.horizontal, 16).padding(.vertical, 14)
                    } else {
                        PlacePanelScroll(level: $panelLevel) {
                            VStack(alignment: .leading, spacing: 16) {
                                if navigation.destination != nil { destinationPanel }
                                else { browsePanel }
                                messages
                            }.padding(.horizontal, 20).padding(.bottom, 18)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: panelContentHeight(available: geometry.size.height), alignment: .top)
                        .clipped()
                        .accessibilityHidden(panelLevel == .collapsed)
                        .id(navigation.destination == nil ? "browse" : "destination")
                    }
                }
                .background {
                    GeometryReader { panel in
                        Color.clear.preference(key: NavigationPanelFrameKey.self, value: panel.frame(in: .global))
                    }
                }
                .background {
                    if navigation.navigating {
                        RoundedRectangle(cornerRadius: 28).fill(.regularMaterial)
                    } else {
                        UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                            .fill(.regularMaterial).ignoresSafeArea(edges: .bottom)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
                .padding(navigation.navigating ? 12 : 0)
            })
            .onPreferenceChange(NavigationPanelFrameKey.self) { tripFrame = $0 }
            .sheet(item: $searchPurpose) { purpose in
                PlaceSearch(navigation: navigation, saved: saved, saveAs: purpose.savedKind) { place in
                    if let kind = purpose.savedKind { saved.save(place, as: kind) }
                    else { selectDestination(place) }
                }
            }
            .sheet(isPresented: $showLibrary) {
                SavedPlacesView(saved: saved) { place in
                    showLibrary = false
                    selectDestination(saved.navigationPlace(place))
                }
            }
            .onChange(of: navigation.navigating) { _, active in
                panelLevel = .standard
                if active {
                    if let place = navigation.destination { saved.rememberDestination(place) }
                    navigation.followLocation()
                }
            }
            .tint(StarPilotTheme.accent)
        }
    }
    private var mapHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                    CompanionNavigationBar(tab: .navigation, developerMode: connection.app.developerMode,
                        navigation: navigation, expanded: $appTabsExpanded, compactIconOnly: true,
                        statusModel: connection.app, select: selectAppTab)
                    navigationOptions
                }.frame(height: 54)
            HStack(alignment: .top, spacing: 12) {
                if navigation.navigating {
                    HStack(alignment: .center, spacing: 18) {
                        Image(systemName: turnSymbol).font(.system(size: 42, weight: .bold)).frame(width: 52)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: turnSymbol)
                        VStack(alignment: .leading, spacing: 4) {
                            ManeuverDistance(label: navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.distanceToTurn))
                            Text(LocalizedStringKey(navigation.instruction)).font(.title3.weight(.semibold)).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white).padding(20)
                    .background(LinearGradient(colors: [StarPilotTheme.accent, StarPilotTheme.guidance], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement(children: .combine)
                } else { Spacer() }
                VStack(spacing: 10) {
                    mapButton("scope", label: "Follow my location") { navigation.followLocation() }
                    if navigation.navigating {
                        mapButton("arrow.up.left.and.arrow.down.right", label: "Show full route") { navigation.showOverview() }
                    }
                }
            }
        }
    }
    private var navigationOptions: some View {
        Menu {
            Button("Submit report", systemImage: "bubble.left.and.exclamationmark.bubble.right") {
                submitReport()
            }
            Button("Reset navigation", systemImage: "arrow.counterclockwise", role: .destructive) {
                Task { await connection.app.navigationServices.resetNavigation() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }.accessibilityLabel("Navigation options")
    }
    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2).accessibilityLabel(label)
    }
    private func panelContentHeight(available: CGFloat) -> CGFloat {
        let count = saved.recentDestinations.count
        func height(expanded: Bool) -> CGFloat {
            if navigation.destination != nil {
                return min(available * (expanded ? 0.58 : 0.42), expanded ? 520 : 360)
            }
            let rows = min(count, expanded ? 10 : 3)
            return min(available * (expanded ? 0.55 : 0.42), rows == 0 ? 252 : 222 + CGFloat(rows) * 66)
        }
        let maximum = height(expanded: true)
        let base = panelLevel == .collapsed ? 0 : height(expanded: expanded)
        return min(maximum, max(0, base - panelDrag))
    }
    private var searchBar: some View {
        Button { search() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search Maps").foregroundStyle(.secondary)
                    Spacer()
                }.font(.title3).padding(14).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("map-search")
    }
    private var browsePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Favorites").font(.title3.bold())
                Spacer()
                Button("See All") { showLibrary = true }.font(.subheadline.weight(.medium))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    shortcut(.home, icon: "house.fill", title: "Home")
                    shortcut(.work, icon: "briefcase.fill", title: "Work")
                    ForEach(saved.library.places.filter { $0.kind == .favorite }.prefix(6)) { place in
                        favoriteShortcut(place)
                    }
                    Button { search(as: .favorite) } label: {
                        shortcutLabel(icon: "plus", title: "Add", subtitle: "Favorite", tint: StarPilotTheme.accent)
                    }.buttonStyle(.plain).accessibilityLabel("Add favorite")
                }.padding(.vertical, 2)
            }
            HStack {
                Text("Recent Destinations").font(.headline)
                Spacer()
                if !saved.recentDestinations.isEmpty {
                    Button("Clear") { saved.clearRecentDestinations() }.font(.subheadline)
                }
            }
            if saved.recentDestinations.isEmpty {
                Text("Destinations you select will appear here.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(saved.recentDestinations.prefix(expanded ? 10 : 3)) { place in
                    RecentDestinationRow(place: place) {
                        selectDestination(saved.navigationPlace(place))
                    }.disabled(navigation.busy)
                }
            }
            Label(connection.connected ? "Comma connected · \(connection.connectionLabel)" : "Connect comma in Settings", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func shortcut(_ kind: SavedPlaceKind, icon: String, title: String) -> some View {
        let place = saved.library.place(kind)
        return Button {
            if let place { selectDestination(saved.navigationPlace(place)) }
            else { search(as: kind) }
        } label: {
            shortcutLabel(icon: icon, title: title, subtitle: place == nil ? "Set address" : place!.name, tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(place != nil && navigation.busy)
        .accessibilityIdentifier(kind == .home ? "home-shortcut" : "work-shortcut")
        .contextMenu {
            Button("Edit address") { search(as: kind) }
            if let place { Button("Remove", role: .destructive) { saved.remove(place) } }
        }
    }
    private func favoriteShortcut(_ place: SavedPlace) -> some View {
        Button { selectDestination(saved.navigationPlace(place)) } label: {
            shortcutLabel(icon: "star.fill", title: place.name, subtitle: "", tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(navigation.busy)
        .contextMenu { Button("Remove favorite", role: .destructive) { saved.remove(place) } }
    }
    private func shortcutLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 60, height: 60).background(tint.opacity(0.12), in: Circle())
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: 78)
    }
    private var destinationPanel: some View {
        NavigationDestinationPanel(navigation: navigation, connection: connection, saved: saved)
    }
    private var tripPanel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened), label: "arrival")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : minutes(navigation.remainingTime), label: "remaining")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.remainingDistance), label: navigation.usingComma ? "distance" : "estimated")
                Spacer(minLength: 0)
                Button(navigation.endingRoute ? "Ending…" : "End") { Task { await navigation.end(connection: connection) } }
                    .font(.headline).foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 13)
                    .background(.red, in: Capsule()).disabled(navigation.busy)
            }

        }
    }
    private func tripMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !navigation.sendToComma, !navigation.locationMessage.isEmpty {
                Button(navigation.locationMessage) { navigation.requestLocation() }.font(.caption)
            }
            if navigation.usingComma, !navigation.commaFeedMessage.isEmpty {
                Text(LocalizedStringKey(navigation.commaFeedMessage)).font(.caption).foregroundStyle(.orange)
                if !connection.app.transport.connected {
                    Button("Open Settings to reconnect", action: openSettings).font(.caption.weight(.medium))
                } else if !navigation.error.isEmpty {
                    Text("If this continues, open ••• → Reset navigation, then choose your destination again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !saved.message.isEmpty { Text(LocalizedStringKey(saved.message)).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var turnSymbol: String {
        if navigation.usingComma && !navigation.commaFeedReady { return "antenna.radiowaves.left.and.right" }
        let text = (navigation.usingComma ? navigation.commaManeuverType + " " + navigation.commaManeuverModifier : navigation.instruction).lowercased()
        if text.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
    private func search(as kind: SavedPlaceKind? = nil) {
        searchPurpose = kind == .home ? .home : kind == .work ? .work : kind == .favorite ? .favorite : .destination
    }
    private func selectDestination(_ place: NavigationPlace) {
        guard !navigation.busy, !navigation.navigating else { return }
        panelLevel = .standard
        saved.rememberDestination(place)
        Task { await navigation.select(place) }
    }
    private func distance(_ meters: Double) -> String {
        distanceUnits.text(meters)
    }
    private func minutes(_ seconds: Double) -> String { NavigationDuration.text(seconds) }
}

private struct ManeuverDistance: View {
    let label: String
    @Environment(\.reduceGalacticalMotion) private var reduceMotion

    var body: some View {
        Text(label)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: label)
    }
}

private struct NavigationPanelFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct PlacePanelLayout<Panel: View>: ViewModifier {
    let overlaid: Bool
    let panel: Panel
    init(overlaid: Bool, @ViewBuilder panel: () -> Panel) {
        self.overlaid = overlaid
        self.panel = panel()
    }
    @ViewBuilder func body(content: Content) -> some View {
        if overlaid {
            content.overlay(alignment: .bottom) { panel }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { panel }
        }
    }
}

struct NavigationHome: View {
    let connection: CommaConnection
    let navigation: NavigationModel
    let saved: SavedPlacesStore
    let selectAppTab: (CompanionTab) -> Void
    let submitReport: () -> Void
    let openSettings: () -> Void
    var body: some View {
        if DuoLayout.isEnabled {
            DuoNavigationHome(connection: connection, navigation: navigation, saved: saved, selectAppTab: selectAppTab, submitReport: submitReport, openSettings: openSettings)
        } else {
            StandardNavigationHome(connection: connection, navigation: navigation, saved: saved, selectAppTab: selectAppTab, submitReport: submitReport, openSettings: openSettings)
        }
    }
}

private struct DuoNavigationHome: View {
    @AppStorage(NavigationDistanceUnits.key) private var distanceUnits = NavigationDistanceUnits.system
    @ObservedObject var connection: CommaConnection
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    @ObservedObject private var bluetooth: BluetoothTransport
    @Environment(\.reduceGalacticalMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var submitReport: () -> Void
    var openSettings: () -> Void
    var selectAppTab: (CompanionTab) -> Void
    @State private var searchPurpose: PlaceSearchPurpose?
    @State private var showLibrary = false
    @State private var tripFrame = CGRect.zero
    @State private var panelLevel: PlacePanelLevel = .standard
    @GestureState private var panelDrag: CGFloat = 0
    private var expanded: Bool { panelLevel == .expanded }
    @State private var appTabsExpanded = true
    init(connection: CommaConnection, navigation: NavigationModel, saved: SavedPlacesStore, selectAppTab: @escaping (CompanionTab) -> Void, submitReport: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.submitReport = submitReport
        self.openSettings = openSettings
        self.selectAppTab = selectAppTab
        self.connection = connection; self.navigation = navigation; self.saved = saved
        bluetooth = connection.bluetooth
    }
    var body: some View {
        GeometryReader { geometry in
            NavigationMapLayer(navigation: navigation, tripFrame: tripFrame, bottomInset: tripFrame.height)
            .modifier(NavigationMapBackground())
            .overlay(alignment: .top) { mapHeader.padding(12) }
            .modifier(PlacePanelLayout(overlaid: navigation.navigating && navigation.usingComma) {
                VStack(spacing: 0) {
                    if !navigation.navigating {
                        PlacePanelHandle(level: $panelLevel, drag: $panelDrag)
                    }
                    if !navigation.error.isEmpty {
                        Text(LocalizedStringKey(navigation.error)).font(.callout).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                            .accessibilityIdentifier("navigation-error-banner")
                    }
                    if !navigation.notice.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(LocalizedStringKey(navigation.notice)).font(.callout)
                            Spacer(minLength: 0)
                            Button { navigation.notice = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Dismiss navigation message")
                        }.foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    if !navigation.navigating {
                        searchBar.padding(.horizontal, 20).padding(.bottom, 12)
                            .simultaneousGesture(panelLevel.dragGesture(level: $panelLevel, offset: $panelDrag))
                    }
                    if navigation.navigating {
                        VStack(alignment: .leading, spacing: 6) {
                            tripPanel
                            messages
                        }
                        .padding(12)
                    } else {
                        PlacePanelScroll(level: $panelLevel) {
                            VStack(alignment: .leading, spacing: 16) {
                                if navigation.destination != nil { destinationPanel }
                                else { browsePanel(width: min(600, geometry.size.width - 24) - 40) }
                                messages
                            }.padding(.horizontal, 20).padding(.bottom, 18)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: panelContentHeight(available: geometry.size.height), alignment: .top)
                        .clipped()
                        .accessibilityHidden(panelLevel == .collapsed)
                        .id(navigation.destination == nil ? "browse" : "destination")
                    }
                }
                .frame(maxWidth: navigation.navigating ? .infinity : 600)
                .background {
                    GeometryReader { panel in
                        Color.clear.preference(key: NavigationPanelFrameKey.self, value: panel.frame(in: .global))
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 24).fill(.regularMaterial)
                }
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(12)
            })
            .onPreferenceChange(NavigationPanelFrameKey.self) { tripFrame = $0 }
            .sheet(item: $searchPurpose) { purpose in
                PlaceSearch(navigation: navigation, saved: saved, saveAs: purpose.savedKind) { place in
                    if let kind = purpose.savedKind { saved.save(place, as: kind) }
                    else { selectDestination(place) }
                }
            }
            .sheet(isPresented: $showLibrary) {
                SavedPlacesView(saved: saved) { place in
                    showLibrary = false
                    selectDestination(saved.navigationPlace(place))
                }
            }
            .onChange(of: navigation.navigating) { _, active in
                panelLevel = .standard
                if active {
                    if let place = navigation.destination { saved.rememberDestination(place) }
                    navigation.followLocation()
                }
            }
            .tint(StarPilotTheme.accent)
        }
    }
    private var mapHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !navigation.navigating {
            HStack(spacing: 8) {
                    if #available(iOS 27.1, *) {
                        // App switching and status are hosted by the system toolbar.
                    } else {
                    CompanionNavigationBar(tab: .navigation, developerMode: connection.app.developerMode,
                        navigation: navigation, expanded: $appTabsExpanded, compactIconOnly: true,
                        statusModel: connection.app, select: selectAppTab)
                    }
                    navigationOptions
                }.frame(height: 54)
            }
            HStack(alignment: .top, spacing: 12) {
                if navigation.navigating {
                    HStack(alignment: .center, spacing: 18) {
                        Image(systemName: turnSymbol).font(.system(size: 42, weight: .bold)).frame(width: 52)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: turnSymbol)
                        VStack(alignment: .leading, spacing: 4) {
                            ManeuverDistance(label: navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.distanceToTurn))
                            Text(LocalizedStringKey(navigation.instruction)).font(.title3.weight(.semibold)).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary).padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement(children: .combine)
                } else { Spacer() }
                if !navigation.navigating {
                VStack(spacing: 10) {
                    mapButton("scope", label: "Follow my location") { navigation.followLocation() }
                    if navigation.navigating {
                        mapButton("arrow.up.left.and.arrow.down.right", label: "Show full route") { navigation.showOverview() }
                    }
                }
            }
            }
        }
    }
    private var navigationOptions: some View {
        Menu {
            if navigation.navigating {
                Button("Follow my location", systemImage: "scope") { navigation.followLocation() }
                Button("Show full route", systemImage: "arrow.up.left.and.arrow.down.right") {
                    navigation.showOverview()
                }
            }
            Button("Submit report", systemImage: "bubble.left.and.exclamationmark.bubble.right") {
                submitReport()
            }
            Button("Reset navigation", systemImage: "arrow.counterclockwise", role: .destructive) {
                Task { await connection.app.navigationServices.resetNavigation() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
        }.accessibilityLabel("Navigation options")
    }
    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2).accessibilityLabel(label)
    }
    private func panelContentHeight(available: CGFloat) -> CGFloat {
        let count = saved.recentDestinations.count
        func height(expanded: Bool) -> CGFloat {
            if navigation.destination != nil {
                return min(available * (expanded ? 0.58 : 0.42), expanded ? 520 : 360)
            }
            let rows = min(count, expanded ? 10 : 3)
            return min(available * (expanded ? 0.55 : 0.42), rows == 0 ? 252 : 222 + CGFloat(rows) * 66)
        }
        let maximum = height(expanded: true)
        let base = panelLevel == .collapsed ? 0 : height(expanded: expanded)
        return min(maximum, max(0, base - panelDrag))
    }
    private var searchBar: some View {
        Button { search() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search Maps").foregroundStyle(.secondary)
                    Spacer()
                }.font(.title3).padding(14).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("map-search")
    }
    private func browsePanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Favorites").font(.title3.bold())
                Spacer()
                Button("See All") { showLibrary = true }.font(.subheadline.weight(.medium))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    shortcut(.home, icon: "house.fill", title: "Home")
                    shortcut(.work, icon: "briefcase.fill", title: "Work")
                    ForEach(saved.library.places.filter { $0.kind == .favorite }.prefix(6)) { place in
                        favoriteShortcut(place)
                    }
                    Button { search(as: .favorite) } label: {
                        shortcutLabel(icon: "plus", title: "Add", subtitle: "Favorite", tint: StarPilotTheme.accent)
                    }.buttonStyle(.plain).accessibilityLabel("Add favorite")
                }.padding(.vertical, 2)
                    .frame(minWidth: max(0, width), alignment: .center)
            }
            HStack {
                Text("Recent Destinations").font(.headline)
                Spacer()
                if !saved.recentDestinations.isEmpty {
                    Button("Clear") { saved.clearRecentDestinations() }.font(.subheadline)
                }
            }
            if saved.recentDestinations.isEmpty {
                Text("Destinations you select will appear here.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(saved.recentDestinations.prefix(expanded ? 10 : 3)) { place in
                    RecentDestinationRow(place: place) {
                        selectDestination(saved.navigationPlace(place))
                    }.disabled(navigation.busy)
                }
            }
            Label(connection.connected ? "Comma connected · \(connection.connectionLabel)" : "Connect comma in Settings", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func shortcut(_ kind: SavedPlaceKind, icon: String, title: String) -> some View {
        let place = saved.library.place(kind)
        return Button {
            if let place { selectDestination(saved.navigationPlace(place)) }
            else { search(as: kind) }
        } label: {
            shortcutLabel(icon: icon, title: title, subtitle: place == nil ? "Set address" : place!.name, tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(place != nil && navigation.busy)
        .accessibilityIdentifier(kind == .home ? "home-shortcut" : "work-shortcut")
        .contextMenu {
            Button("Edit address") { search(as: kind) }
            if let place { Button("Remove", role: .destructive) { saved.remove(place) } }
        }
    }
    private func favoriteShortcut(_ place: SavedPlace) -> some View {
        Button { selectDestination(saved.navigationPlace(place)) } label: {
            shortcutLabel(icon: "star.fill", title: place.name, subtitle: "", tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(navigation.busy)
        .contextMenu { Button("Remove favorite", role: .destructive) { saved.remove(place) } }
    }
    private func shortcutLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 60, height: 60).background(tint.opacity(0.12), in: Circle())
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: 78)
    }
    private var destinationPanel: some View {
        NavigationDestinationPanel(navigation: navigation, connection: connection, saved: saved)
    }
    private var tripPanel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened), label: "arrival")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : minutes(navigation.remainingTime), label: "remaining")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.remainingDistance), label: navigation.usingComma ? "distance" : "estimated")
                Spacer(minLength: 0)
                Button(navigation.endingRoute ? "Ending…" : "End") { Task { await navigation.end(connection: connection) } }
                    .font(.headline).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 12)
                    .background(.red, in: Capsule()).disabled(navigation.busy)
                navigationOptions
            }

        }
    }
    private func tripMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !navigation.sendToComma, !navigation.locationMessage.isEmpty {
                Button(navigation.locationMessage) { navigation.requestLocation() }.font(.caption)
            }
            if navigation.usingComma, !navigation.commaFeedMessage.isEmpty {
                Text(LocalizedStringKey(navigation.commaFeedMessage)).font(.caption).foregroundStyle(.orange)
                if !connection.app.transport.connected {
                    Button("Open Settings to reconnect", action: openSettings).font(.caption.weight(.medium))
                } else if !navigation.error.isEmpty {
                    Text("If this continues, open ••• → Reset navigation, then choose your destination again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !saved.message.isEmpty { Text(LocalizedStringKey(saved.message)).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var turnSymbol: String {
        if navigation.usingComma && !navigation.commaFeedReady { return "antenna.radiowaves.left.and.right" }
        let text = (navigation.usingComma ? navigation.commaManeuverType + " " + navigation.commaManeuverModifier : navigation.instruction).lowercased()
        if text.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
    private func search(as kind: SavedPlaceKind? = nil) {
        searchPurpose = kind == .home ? .home : kind == .work ? .work : kind == .favorite ? .favorite : .destination
    }
    private func selectDestination(_ place: NavigationPlace) {
        guard !navigation.busy, !navigation.navigating else { return }
        panelLevel = .standard
        saved.rememberDestination(place)
        Task { await navigation.select(place) }
    }
    private func distance(_ meters: Double) -> String {
        distanceUnits.text(meters)
    }
    private func minutes(_ seconds: Double) -> String { NavigationDuration.text(seconds) }
}

private struct NavigationDestinationPanel: View {
    @AppStorage(NavigationDistanceUnits.key) private var distanceUnits = NavigationDistanceUnits.system
    @State private var choosingStart = false
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var connection: CommaConnection
    @ObservedObject var saved: SavedPlacesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let place = navigation.destination {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name).font(.title2.bold()).lineLimit(2)
                        if !place.address.isEmpty {
                            Text(place.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button { navigation.clearPreview() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }.disabled(navigation.busy).accessibilityLabel("Close destination")
                }
                HStack(spacing: 16) {
                    Button {
                        if let favorite = saved.library.favorite(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude) {
                            saved.remove(favorite)
                        } else { saved.save(place, as: .favorite) }
                    } label: {
                        Label(saved.library.favorite(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude) == nil ?
                            "Add Favorite" : "Saved", systemImage: "star.fill")
                    }.font(.subheadline.weight(.medium))
                    Menu {
                        Button("Save as Home") { saved.save(place, as: .home) }
                        Button("Save as Work") { saved.save(place, as: .work) }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("Save place options")
                }
            }
            HStack {
                Button { choosingStart = true } label: {
                    Label("From: \(navigation.plannedStart?.name ?? "Current location")", systemImage: "flag")
                        .multilineTextAlignment(.leading)
                }.accessibilityHint("Choose a starting point for a route preview")
                Spacer()
                if navigation.plannedStart != nil {
                    Button("Use my location") { Task { await navigation.preview(from: nil) } }
                }
            }
            .font(.subheadline)
            .sheet(isPresented: $choosingStart) {
                PlaceSearch(navigation: navigation, saved: saved, saveAs: nil, choosingStart: true) { place in
                    Task { await navigation.preview(from: place) }
                }
            }
            Picker("Route guidance", selection: Binding(get: { navigation.sendToComma }, set: { useComma in
                Task { await navigation.selectGuidanceSource(comma: useComma) }
            })) {
                Text("Comma").tag(true)
                Text("iPhone").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(navigation.busy)

            if navigation.sendToComma {
                Button {
                    Task { await navigation.start(connection: connection) }
                } label: {
                    Text(navigation.busy ? "Sending destination…" : "Send to comma")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(navigation.busy || !connection.connected)
                Text(connection.connected ? "Your comma will calculate the route." : "Connect to comma or choose iPhone for directions.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if navigation.busy {
                ProgressView("Getting directions…")
            } else if navigation.routes.isEmpty {
                Button("Get directions") { Task { await navigation.calculateRoutes(refresh: false) } }
                    .buttonStyle(.borderedProminent)
            } else {
                ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                    Button { navigation.chooseRoute(index) } label: {
                        HStack {
                            Image(systemName: navigation.selectedRoute == index ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(NavigationDuration.text(route.expectedTravelTime)).font(.headline)
                                Text("\(distanceUnits.text(route.distance)) · \(route.name)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(navigation.selectedRoute == index ? .isSelected : [])
                }
                if navigation.plannedStart == nil {
                    Button("Start on iPhone") { Task { await navigation.start(connection: connection) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Preview from your chosen starting point. Use your current location to start guidance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NavigationMapBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container)
            .overlay {
                LinearGradient(colors: [Color.purple.opacity(0.035), Color.purple.opacity(0.01), .clear],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                    .ignoresSafeArea(.container)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
