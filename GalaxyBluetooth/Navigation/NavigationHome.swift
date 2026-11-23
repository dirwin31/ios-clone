import SwiftUI
import MapKit

struct NavigationMapLayer: View {
    @ObservedObject var navigation: NavigationModel
    @AppStorage("navigation.appleStyle") private var appleStyle = GalaxyAppleMap.streets
    let markerPerspective: DriveMarkerPerspective
    let headerBottom: CGFloat
    let tripFrame: CGRect
    @AppStorage(NavigationMapPreference.enabledKey) private var useMapbox = true
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""

    var body: some View {
        Group {
            if useMapbox && token.hasPrefix("pk.") {
                MapboxDriveMap(navigation: navigation, token: token, markerPerspective: markerPerspective, tripFrame: tripFrame, headerBottom: headerBottom)
                    .ignoresSafeArea(.container, edges: navigation.navigating ? .top : [])
                    .id(token)
            } else if navigation.navigating && navigation.usingComma {
                CommaFollowingMap(navigation: navigation, bottomInset: tripFrame.height)
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
                .mapStyle(appleStyle.style)
                .mapControls { MapCompass() }
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
    @State private var markerPerspective = DriveMarkerPerspective()
    @State private var headerBottom: CGFloat = 0
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
            NavigationMapLayer(navigation: navigation, markerPerspective: markerPerspective,
                               headerBottom: headerBottom, tripFrame: tripFrame)
            .overlay(alignment: .top) {
                mapHeader.padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
            }
            .modifier(PlacePanelLayout(guiding: navigation.navigating) {
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
                                QueuedPlaceStatus()
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
                    if !navigation.navigating {
                        UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                            .fill(.regularMaterial).ignoresSafeArea(edges: .bottom)
                    }
                }
                .frame(maxWidth: navigation.navigating ? 430 : nil)
                .modifier(TripBarGlass(active: navigation.navigating))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tripFrame = $0 }
                .overlay(alignment: .top) { TripBarFollowMarker(markerPerspective: markerPerspective, navigation: navigation) }
                .shadow(color: .black.opacity(navigation.navigating ? 0.06 : 0.12), radius: 12, y: -2)
                .padding(navigation.navigating ? 12 : 0)
                .opacity(searchPurpose == nil ? 1 : 0)
                .allowsHitTesting(searchPurpose == nil)
                .accessibilityHidden(searchPurpose != nil)
            })
            .pageSheet(item: $searchPurpose) { purpose in
                PlaceSearch(navigation: navigation, saved: saved, saveAs: purpose.savedKind, choosingStart: purpose == .start) { place in
                    if purpose == .start { Task { await navigation.preview(from: place) } }
                    else if let kind = purpose.savedKind { saved.save(place, as: kind) }
                    else { selectDestination(place) }
                }
            }
            .pageSheet(isPresented: $showLibrary) {
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
                            if let junction = navigation.mappedJunction {
                                Text("Mapped at junction · \(junction.labels) · \(distance(Double(junction.meters)))")
                                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
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
        NavigationDestinationPanel(chooseStart: { searchPurpose = .start }, navigation: navigation, connection: connection, saved: saved)
    }
    private var tripPanel: some View {
        TripSummaryRow(navigation: navigation, connection: connection, units: distanceUnits) { EmptyView() }
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
            if !navigation.navigating, !saved.message.isEmpty { Text(LocalizedStringKey(saved.message)).font(.caption).foregroundStyle(.secondary) }
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

struct TripBarFollowMarker: View {
    let markerPerspective: DriveMarkerPerspective
    @ObservedObject var navigation: NavigationModel
    @AppStorage(NavigationMapPreference.enabledKey) private var useMapbox = true
    @AppStorage(NavigationMapPreference.tokenKey) private var token = ""

    var body: some View {
        if useMapbox && token.hasPrefix("pk.") && navigation.navigating && navigation.followsUser {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let fresh = navigation.usingComma
                    ? navigation.commaFeedReady && navigation.commaPosition != nil &&
                        clock.date.timeIntervalSince(navigation.commaPositionSampleDate) <= 4
                    : navigation.goodLocation != nil
                if fresh {
                    DrivePositionMarker(perspective: markerPerspective, following: true, comma: navigation.usingComma)
                        .offset(y: -DrivePositionMarker.barClearance - DrivePositionMarker.diameter)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct TripSummaryRow<Options: View>: View {
    @ObservedObject var navigation: NavigationModel
    let connection: CommaConnection
    let units: NavigationDistanceUnits
    @ViewBuilder let options: () -> Options
    @Environment(\.dynamicTypeSize) private var typeSize

    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 23

    @ScaledMetric(relativeTo: .headline) private var compactValueSize: CGFloat = 18

    var body: some View {
        if typeSize.isAccessibilitySize {
            stackedSummary
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    metrics(size: valueSize, spacing: 18)
                    Spacer(minLength: 0)
                    actions
                }
                HStack(spacing: 6) {
                    metrics(size: compactValueSize, spacing: 8)
                    Spacer(minLength: 0)
                    actions
                }
                stackedSummary
            }
        }
    }

    private var stackedSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                metrics(size: valueSize, spacing: 18)
                VStack(alignment: .leading, spacing: 10) { metricItems(size: valueSize) }
            }
            actions.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func metrics(size: CGFloat, spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) { metricItems(size: size) }
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func metricItems(size: CGFloat) -> some View {
        metric(Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened), "arrival", size: size)
        metric(NavigationDuration.text(navigation.remainingTime), "remaining", size: size)
        metric(units.text(navigation.remainingDistance), "distance", size: size)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(navigation.endingRoute ? "Ending…" : "End") { Task { await navigation.end(connection: connection) } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                .background(StarPilotTheme.guidance, in: Capsule()).disabled(navigation.busy)
            options()
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func metric(_ value: String, _ label: LocalizedStringKey, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(navigation.usingComma && !navigation.commaFeedReady ? "—" : value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TripBarGlass: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        } else if #available(iOS 26.0, *) {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
    }
}

private struct PlacePanelLayout<Panel: View>: ViewModifier {
    let guiding: Bool
    let panel: Panel
    init(guiding: Bool, @ViewBuilder panel: () -> Panel) {
        self.guiding = guiding
        self.panel = panel()
    }
    @ViewBuilder func body(content: Content) -> some View {
        if guiding {
            content.overlay(alignment: .bottom) { panel.fixedSize(horizontal: false, vertical: true) }
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

struct QueuedPlaceStatus: View {
    @ObservedObject private var inbox = ShareInbox.shared
    var body: some View {
        if let pending = inbox.waiting, let place = pending.place {
            HStack {
                Label("Queued for comma: \(place.name)", systemImage: "clock")
                Spacer()
                Button("Cancel") { inbox.cancelQueuedPlace(pending.id) }
            }.font(.subheadline)
        }
    }
}

private struct NavigationDestinationPanel: View {
    @AppStorage("navigation.offerPhoneTrip") private var offerPhoneTrip = false
    @AppStorage("navigation.phoneRouter") private var router = "Automatic"
    @AppStorage("navigation.parkedPhonePreview") private var parkedPreview = false
    @AppStorage(NavigationDistanceUnits.key) private var distanceUnits = NavigationDistanceUnits.system
    let chooseStart: () -> Void
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
                Button { chooseStart() } label: {
                    Label("From: \(navigation.plannedStart?.name ?? "Current location")", systemImage: "flag")
                        .multilineTextAlignment(.leading)
                }.accessibilityHint("Choose a starting point for a route preview")
                Spacer()
                if navigation.plannedStart != nil {
                    Button("Use my location") { Task { await navigation.preview(from: nil) } }
                }
            }
            .font(.subheadline)
            if !offerPhoneTrip {
                Picker("Route guidance", selection: Binding(get: { navigation.sendToComma }, set: { useComma in
                    Task { await navigation.selectGuidanceSource(comma: useComma) }
                })) {
                    Text("Comma").tag(true)
                    Text("iPhone").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(navigation.busy)
            }
            if !navigation.sendToComma && !offerPhoneTrip {
                Text("Your phone handles directions for this trip. Starting it leaves any route on your comma alone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if (offerPhoneTrip || !navigation.sendToComma), !navigation.busy, !navigation.routes.isEmpty,
               offerPhoneTrip || ExternalNavigator(rawValue: router) == nil && (router != "Mapbox Navigator" || navigation.plannedStart != nil) {
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
                if !offerPhoneTrip, let selected = navigation.route {
                    if let body = selected.commaPreview {
                        if !parkedPreview {
                            Button {
                                parkedPreview = true
                            } label: {
                                Label("Enable parked route preview", systemImage: "car.fill")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Adds a preview button for this and future compatible routes.")
                        } else {
                            ParkedPhoneRoutePreview(bodyData: body, connection: connection)
                                .id(body)
                        }
                    } else if parkedPreview {
                        Text("Preview with comma supports short Mapbox Driving and Traffic routes.").font(.footnote)
                    }
                }
            }
            RouteStartAction(navigation: navigation, connection: connection)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct RouteStartAction: View {
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var connection: CommaConnection
    @ObservedObject private var inbox = ShareInbox.shared
    @AppStorage("navigation.offerPhoneTrip") private var offerPhoneTrip = false
    var compact = false
    @AppStorage("navigation.phoneRouter") private var router = "Automatic"
    @AppStorage(NavigationMapPreference.tokenKey) private var mapToken = ""
    @State private var navigatorTrip: NavigatorTrip?
    private struct NavigatorTrip: Identifiable {
        let id = UUID()
        let origin: CLLocationCoordinate2D
        let destination: CLLocationCoordinate2D
        let token: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if navigation.sendToComma && !offerPhoneTrip {
                let queued = inbox.waiting?.place
                let samePlace = queued != nil && queued?.latitude == navigation.destination?.coordinate.latitude
                    && queued?.longitude == navigation.destination?.coordinate.longitude
                Button {
                    if connection.connected {
                        if let pending = inbox.waiting { inbox.cancelQueuedPlace(pending.id) }
                        Task { await navigation.start(connection: connection) }
                    } else if let place = navigation.destination { inbox.queuePlace(place) }
                } label: {
                    Text(navigation.busy ? "Sending destination…" : samePlace ? "Queued for comma" :
                            connection.connected ? "Send to comma" : queued == nil ? "Send when connected" : "Replace queued destination")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .disabled(navigation.busy || samePlace)
                if !compact {
                    Text(connection.connected ? "Your comma calculates the turns. Choose iPhone above to get directions using your phone instead." : "Send when connected queues the destination for your comma. Choose iPhone above for directions now.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            } else if !offerPhoneTrip, let external = ExternalNavigator(rawValue: router), let place = navigation.destination,
                      let url = external.directions(to: place.coordinate) {
                Link("Open destination in " + external.rawValue, destination: url)
                if !compact {
                    Text("The selected service opens with your destination and handles guidance from your location.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            } else if !offerPhoneTrip && router == "Mapbox Navigator" && navigation.plannedStart == nil {
                Button("Start Mapbox Navigator on iPhone") {
                    guard let place = navigation.destination else { return }
                    guard mapToken.hasPrefix("pk.") else {
                        navigation.error = "Save a Mapbox public token in Navigation settings."
                        return
                    }
                    guard let origin = navigation.goodLocation else {
                        navigation.requestLocation()
                        navigation.error = "Waiting for an accurate current location."
                        return
                    }
                    navigatorTrip = NavigatorTrip(origin: origin.coordinate, destination: place.coordinate, token: mapToken)
                }
                .fullScreenCover(item: $navigatorTrip) { trip in
                    MapboxNavigatorScreen(origin: trip.origin, destination: trip.destination, token: trip.token)
                }
            } else if navigation.busy {
                ProgressView("Getting directions…")
            } else if navigation.routes.isEmpty {
                Button("Get directions") { Task { await navigation.calculateRoutes(refresh: false) } }
            } else if navigation.plannedStart == nil {
                Button(offerPhoneTrip ? "Start Route" : "Start on iPhone") {
                    Task { await navigation.start(connection: connection, phoneRouteOnComma: offerPhoneTrip) }
                }
                .disabled(offerPhoneTrip && (!connection.connected || navigation.route?.commaPreview == nil))
                if offerPhoneTrip && (!compact || !connection.connected || navigation.route?.commaPreview == nil) {
                    Text(!connection.connected ? "Connect to your paired comma to start." : navigation.route?.commaPreview == nil
                         ? "This route exceeds the comma’s route transfer limit. Choose a shorter trip."
                         : "Uses the selected iPhone route on your comma.").font(.footnote)
                }
            } else {
                Text("Preview from your chosen starting point. Use your current location to start guidance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct ParkedPhoneRoutePreview: View {
    let bodyData: Data
    @ObservedObject var connection: CommaConnection
    @State private var loading = false
    @State private var message = ""
    @State private var preview: Reply?
    private struct Reply: Decodable, Identifiable {
        struct Point: Decodable { let latitude, longitude: Double }
        let version, steps: Int
        let points: [Point]
        let firstInstruction: String
        var id: Int { version }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await check() }
            } label: {
                Label(loading ? "Checking route…" : "Preview with comma", systemImage: "car.fill")
            }
            .buttonStyle(.bordered)
            .disabled(loading || !connection.connected)
            Text(connection.connected ? "Check this route on your parked comma and see the result here before starting a trip." : "Connect to your parked comma to preview this route.")
                .font(.footnote).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.footnote) }
        }.sheet(item: $preview) { reply in
            NavigationStack {
                VStack {
                    Map {
                        MapPolyline(coordinates: reply.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                            .stroke(.purple, lineWidth: 5)
                    }
                    Text("Comma read \(reply.steps) route steps.").font(.headline)
                    if !reply.firstInstruction.isEmpty { Text(reply.firstInstruction) }
                    Text("Parked preview only").font(.footnote)
                }
                .navigationTitle("Route from comma")
                .toolbar { Button("Done") { preview = nil } }
            }
        }
    }

    @MainActor private func check() async {
        guard !loading else { return }
        loading = true
        message = ""
        defer { loading = false }
        let before = connection.session
        do {
            _ = try await connection.ensureDeviceIdentity()
            guard connection.session == before else { throw BridgeError.message("Connection changed.") }
            let status = try await connection.transport.request(path: "/api/navigation/status", method: "GET", headers: [:], body: Data())
            guard status.status == 200, connection.session == before else { throw BridgeError.message("Couldn’t verify your comma.") }
            let fields = try JSONSerialization.jsonObject(with: status.bodyData) as? [String: Any]
            guard fields?["phoneRoutePreviewVersion"] as? Int == 1 else {
                throw BridgeError.message("This comma firmware does not support iPhone route previews.")
            }
            let response = try await connection.transport.request(path: "/api/navigation/phone-preview", method: "POST",
                headers: ["content-type": "application/json"], body: bodyData)
            guard connection.session == before else { throw BridgeError.message("Connection changed. Try the preview again.") }
            guard response.status == 200 else { throw BridgeError.message(response.status == 409 ? "Park and reconnect to preview the route." : "Comma could not preview this route (HTTP \(response.status)).") }
            let reply = try JSONDecoder().decode(Reply.self, from: response.bodyData)
            guard reply.version == 1, (1...256).contains(reply.steps), (2...512).contains(reply.points.count),
                  reply.points.allSatisfy({ CLLocationCoordinate2DIsValid(.init(latitude: $0.latitude, longitude: $0.longitude)) }) else {
                throw BridgeError.message("Comma returned an incomplete preview.")
            }
            preview = reply
        } catch { message = error.localizedDescription }
    }
}
