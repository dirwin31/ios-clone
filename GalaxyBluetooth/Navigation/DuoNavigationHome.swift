import SwiftUI
import MapKit

struct DuoNavigationHome: View {
    @ObservedObject var connection: CommaConnection
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    let selectAppTab: (CompanionTab) -> Void
    let submitReport: () -> Void
    let openSettings: () -> Void

    @AppStorage(NavigationDistanceUnits.key) private var units = NavigationDistanceUnits.system
    @AppStorage("navigation.offerPhoneTrip") private var handoff = false
    @AppStorage("navigation.parkedPhonePreview") private var parkedPreview = false
    @AppStorage("navigation.phoneRouter") private var router = "Automatic"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.reduceGalacticalMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var searchingPlaces = false
    @State private var collapsed = true
    @State private var expanded = false
    @State private var library = false
    @State private var showNavigationSettings = false
    @State private var details = false
    @State private var auxiliarySearch: PlaceSearchPurpose?
    @State private var markerPerspective = DriveMarkerPerspective()
    @State private var headerBottom: CGFloat = 0
    @State private var tripFrame = CGRect.zero
    @State private var tabsExpanded = false

    var body: some View {
        GeometryReader { geo in
            if navigation.navigating {
                drive
            } else {
                let wide = geo.size.width >= 680 && !typeSize.isAccessibilitySize
                let width = min(354, geo.size.width * 0.43)
                let height = min(max(0, geo.size.height - 16), plannerHeight(geo.size.height, wide: wide))
                let insets = EdgeInsets(top: 0, leading: wide ? width + 20 : 0,
                                        bottom: wide ? 0 : height + 16, trailing: 0)
                ZStack(alignment: wide ? .bottomLeading : .bottom) {
                    NavigationMapLayer(navigation: navigation, markerPerspective: markerPerspective,
                                       headerBottom: headerBottom, tripFrame: .zero, plannerInsets: insets)
                        .ignoresSafeArea(.container)
                    mapButtons.frame(maxHeight: .infinity, alignment: .top)
                    planner
                        .frame(width: wide ? width : nil, height: height)
                        .modifier(DuoMapGlass(radius: 28))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .animation(reduceMotion ? nil : CompanionMotion.selection, value: collapsed)
                }
            }
        }
        .tint(StarPilotTheme.guidance)
        .onChange(of: query) { _, text in
            if searchingPlaces { navigation.suggest(text, choosingStart: false) }
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { searchingPlaces = true; collapsed = false }
        }
        .onChange(of: navigation.navigating) { _, active in
            finishSearch()
            details = false; collapsed = false; expanded = false
            if active {
                if let place = navigation.destination { saved.rememberDestination(place) }
                navigation.followLocation()
            }
        }
        .onDisappear { if searchingPlaces { finishSearch() } }
        .sheet(item: $auxiliarySearch) { purpose in
            PlaceSearch(navigation: navigation, saved: saved, saveAs: purpose.savedKind, choosingStart: purpose == .start) { place in
                if purpose == .start { Task { await navigation.preview(from: place) } }
                else if let kind = purpose.savedKind { saved.save(place, as: kind) }
            }
        }
        .sheet(isPresented: $library) {
            SavedPlacesView(saved: saved) { place in
                library = false
                select(saved.navigationPlace(place))
            }
        }
        .sheet(isPresented: $showNavigationSettings) { NavigationMapSettings(model: connection.app) }
    }

    private func plannerHeight(_ available: CGFloat, wide: Bool) -> CGFloat {
        if searchingPlaces { return min(available * (wide ? 0.95 : 0.78), 490) }
        if collapsed { return typeSize.isAccessibilitySize ? 170 : (navigation.destination == nil ? 128 : 89) }
        if wide { return min(available - 16, 490) }
        if expanded || typeSize.isAccessibilitySize { return available * 0.78 }
        let preview = navigation.destination != nil
        return min(available * (preview ? 0.62 : 0.49), preview ? 364 : (saved.recentDestinations.isEmpty ? 210 : 300))
    }

    private var map: some View {
        NavigationMapLayer(navigation: navigation, markerPerspective: markerPerspective,
                           headerBottom: headerBottom, tripFrame: navigation.navigating ? tripFrame : .zero)
    }

    private var mapButtons: some View {
            HStack {
                if #unavailable(iOS 27.1) {
                    CompanionNavigationBar(tab: .navigation, developerMode: connection.app.developerMode,
                        navigation: navigation, expanded: $tabsExpanded, compactIconOnly: true,
                        statusModel: connection.app, select: selectAppTab)
                }
                Spacer()
                Button { navigation.followLocation() } label: {
                    Image(systemName: "location.fill").frame(width: 44, height: 44)
                }
                .modifier(DuoMapGlass(radius: 22)).accessibilityLabel("Follow my location")
            }
            .padding(10)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
    }

    private var planner: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !searchingPlaces { handle }
            if let place = navigation.destination {
                destinationHeader(place)
                if !collapsed {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            alerts
                            itinerary
                            routeChoices
                            messages
                            QueuedPlaceStatus()
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("duo-itinerary")
                    Divider()
                    RouteStartAction(navigation: navigation, connection: connection, compact: true)
                        .buttonStyle(DuoRouteButtonStyle())
                        .padding(.horizontal, 16).padding(.vertical, 9)
                }
            } else {
                searchField
                if collapsed && !searchingPlaces {
                    Button {
                        collapsed = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark")
                            Text("Saved places & recents")
                            Image(systemName: "chevron.up").font(.caption2.bold())
                        }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            alerts
                            if searchingPlaces && !query.isEmpty { searchResults }
                            else { savedPlaces }
                            QueuedPlaceStatus()
                            messages
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var handle: some View {
        Button {
            collapsed.toggle()
            expanded = false
        } label: {
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 34, height: 4)
                .frame(maxWidth: .infinity).frame(height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height < -12 { collapsed = false; expanded = true }
            if value.translation.height > 12 { collapsed = true; expanded = false }
        })
        .accessibilityLabel(collapsed ? "Expand place panel" : "Collapse place panel")
        .accessibilityIdentifier("place-panel-handle")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(StarPilotTheme.guidance)
                TextField("Where to?", text: $query)
                    .font(.headline).focused($searchFocused).submitLabel(.search)
                    .accessibilityLabel("Search places or addresses").accessibilityIdentifier("map-search")
                    .onSubmit { searchFocused = false }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 32, minHeight: 44)
                    }.accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(.primary.opacity(0.065), in: Capsule())
            if searchingPlaces { Button("Cancel", action: finishSearch).font(.subheadline.weight(.semibold)) }
            else { options }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    @ViewBuilder private var searchResults: some View {
        ForEach(navigation.suggestions, id: \.self) { item in
            Button {
                Task { if let place = await navigation.resolve(item) { select(place) } }
            } label: { placeRow(item.title, subtitle: item.subtitle, symbol: "mappin") }
            .disabled(navigation.searching).accessibilityIdentifier("place-search-result")
        }
        ForEach(navigation.results) { place in
            Button { select(place) } label: { placeRow(place.name, subtitle: place.address, symbol: "mappin") }
                .accessibilityIdentifier("place-search-result")
        }
        if navigation.searching { ProgressView("Searching…") }
        if !navigation.searchMessage.isEmpty { Text(navigation.searchMessage).font(.subheadline).foregroundStyle(.secondary) }
    }

    private func placeRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(StarPilotTheme.guidance)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }

    private var savedPlaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved places").font(.headline)
                Spacer()
                Button("View all") { finishSearch(); library = true }.font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    shortcut(.home, title: "Home", symbol: "house.fill")
                    shortcut(.work, title: "Work", symbol: "briefcase.fill")
                    ForEach(saved.library.places.filter { $0.kind == .favorite }) { place in
                        Button { select(saved.navigationPlace(place)) } label: { chip(place.name, symbol: "star.fill") }
                            .contextMenu { Button("Remove favorite", role: .destructive) { saved.remove(place) } }
                    }
                    Button { startAuxiliary(.favorite) } label: { chip("Add", symbol: "plus") }
                        .accessibilityLabel("Add favorite")
                }
            }
            if !saved.recentDestinations.isEmpty {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Menu { Button("Clear recent destinations", role: .destructive) { saved.clearRecentDestinations() } } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel("Recent destination options")
                }
                ForEach(saved.recentDestinations) { place in
                    Button { select(saved.navigationPlace(place)) } label: {
                        placeRow(place.name, subtitle: place.address, symbol: "clock")
                    }
                    Divider()
                }
            }
        }.buttonStyle(.plain)
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            .foregroundStyle(StarPilotTheme.guidance).padding(.horizontal, 12).frame(minHeight: 44)
            .background(StarPilotTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
    }

    private func shortcut(_ kind: SavedPlaceKind, title: String, symbol: String) -> some View {
        let place = saved.library.place(kind)
        return Button {
            if let place { select(saved.navigationPlace(place)) }
            else { startAuxiliary(kind == .home ? .home : .work) }
        } label: { chip(title, symbol: symbol) }
        .accessibilityIdentifier(kind == .home ? "home-shortcut" : "work-shortcut")
        .contextMenu {
            Button("Edit address") { startAuxiliary(kind == .home ? .home : .work) }
            if let place { Button("Remove", role: .destructive) { saved.remove(place) } }
        }
    }

    private func destinationHeader(_ place: NavigationPlace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse").font(.title3.weight(.semibold))
                .foregroundStyle(.white).frame(width: 42, height: 42)
                .background(StarPilotTheme.guidance.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(StarPilotTheme.title(21)).lineLimit(2)
                if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            options
            Button { navigation.clearPreview(); collapsed = false; expanded = false } label: {
                Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 44, height: 44)
            }.disabled(navigation.busy).accessibilityLabel("Close destination")
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var itinerary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { startAuxiliary(.start) } label: {
                    placeRow(navigation.plannedStart?.name ?? "Current location", subtitle: "Starting point", symbol: "location.circle.fill")
                }.buttonStyle(.plain)
                if navigation.plannedStart != nil {
                    Button("Use GPS") { Task { await navigation.preview(from: nil) } }
                }
            }
            Divider().padding(.leading, 40)
            HStack(spacing: 12) {
                Image(systemName: handoff || navigation.sendToComma ? "car.fill" : "iphone")
                    .frame(width: 28).foregroundStyle(StarPilotTheme.guidance)
                if handoff {
                    Text("iPhone route to comma").font(.subheadline.weight(.semibold))
                } else {
                    Menu {
                        Picker("Directions", selection: Binding(get: { navigation.sendToComma }, set: { value in
                            Task { await navigation.selectGuidanceSource(comma: value) }
                        })) {
                            Text("Comma").tag(true)
                            Text("iPhone").tag(false)
                        }
                    } label: {
                        HStack { Text(navigation.sendToComma ? "Comma directions" : "iPhone directions")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }.disabled(navigation.busy)
                }
                Spacer(minLength: 0)
                if let place = navigation.destination {
                    Menu {
                        if let favorite = saved.library.favorite(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude) {
                            Button("Remove favorite", systemImage: "star.slash") { saved.remove(favorite) }
                        } else { Button("Add favorite", systemImage: "star") { saved.save(place, as: .favorite) } }
                        Button("Save as Home", systemImage: "house") { saved.save(place, as: .home) }
                        Button("Save as Work", systemImage: "briefcase") { saved.save(place, as: .work) }
                    } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Save place options")
                }
            }
        }
    }

    @ViewBuilder private var routeChoices: some View {
        if !navigation.sendToComma, !navigation.busy, !navigation.routes.isEmpty,
           handoff || (ExternalNavigator(rawValue: router) == nil && (router != "Mapbox Navigator" || navigation.plannedStart != nil)) {
            Text(navigation.routes.count == 1 ? "Route" : "Choose a route").font(.headline)
            ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                let selected = index == navigation.selectedRoute
                Button { navigation.chooseRoute(index) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? StarPilotTheme.guidance : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(NavigationDuration.text(route.expectedTravelTime)).font(.title3.bold()).monospacedDigit()
                            Text([units.text(route.distance), route.name].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? StarPilotTheme.accent.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay { if selected { RoundedRectangle(cornerRadius: 14).strokeBorder(StarPilotTheme.guidance, lineWidth: 1.5) } }
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("duo-route-\(index)")
            }
            if !handoff, let body = navigation.route?.commaPreview {
                DisclosureGroup("Parked preview", isExpanded: $details) {
                    if parkedPreview { ParkedPhoneRoutePreview(bodyData: body, connection: connection).id(body) }
                    else { Button("Enable parked route preview") { parkedPreview = true } }
                }.font(.subheadline)
            }
        }
    }

    private var drive: some View {
        map.ignoresSafeArea(.container)
            .overlay(alignment: .topLeading) {
                maneuver
                    .frame(maxWidth: 450, alignment: .leading).padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            if navigation.usingComma && !navigation.commaFeedReady {
                                Text("Awaiting guidance").font(.headline)
                            } else {
                                let eta = Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened)
                                Text("Arrive \(eta)").font(StarPilotTheme.title(22)).monospacedDigit()
                                Text("\(NavigationDuration.text(navigation.remainingTime)) · \(units.text(navigation.remainingDistance))")
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }.accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        Button { Task { await navigation.end(connection: connection) } } label: {
                            Text(navigation.endingRoute ? "Ending…" : "End")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                                .padding(.horizontal, 15).frame(minHeight: 44)
                                .background(.red.opacity(0.10), in: Capsule())
                        }.disabled(navigation.busy).accessibilityLabel(navigation.endingRoute ? "Ending route" : "End route")
                        options
                    }
                    alerts
                    messages
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 440)
                .modifier(DuoMapGlass(radius: 24))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tripFrame = $0 }
                .overlay(alignment: .top) { TripBarFollowMarker(markerPerspective: markerPerspective, navigation: navigation) }
                .padding(12)
            }
    }

    private var maneuver: some View {
        HStack(spacing: 14) {
            Image(systemName: turnSymbol).font(.system(size: 32, weight: .bold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : CompanionMotion.selection, value: turnSymbol)
                .foregroundStyle(.white).frame(width: 56, height: 56)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                if !navigation.usingComma || navigation.commaFeedReady {
                    Text(units.text(navigation.distanceToTurn)).font(.title.bold()).monospacedDigit()
                }
                Text(LocalizedStringKey(navigation.instruction)).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let junction = navigation.mappedJunction {
                    Text("\(junction.labels) · \(units.text(Double(junction.meters)))").font(.caption)
                        .accessibilityLabel("Mapped at junction: \(junction.labels), \(units.text(Double(junction.meters)))")
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white).padding(14)
        .background(LinearGradient(colors: [StarPilotTheme.guidance, StarPilotTheme.panel],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private var turnSymbol: String {
        if navigation.usingComma && !navigation.commaFeedReady { return navigation.reroutingPhoneTrip ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right" }
        let maneuver = (navigation.usingComma ? navigation.commaManeuverType + " " + navigation.commaManeuverModifier : navigation.instruction).lowercased()
        if maneuver.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if maneuver.contains("u-turn") || maneuver.contains("uturn") { return "arrow.uturn.down" }
        if maneuver.contains("left") { return "arrow.turn.up.left" }
        if maneuver.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    private var options: some View {
        Menu {
            Button("Navigation settings", systemImage: "slider.horizontal.3") { showNavigationSettings = true }
            if navigation.navigating {
                Button("Follow my location", systemImage: "scope") { navigation.followLocation() }
                Button("Show full route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { navigation.showOverview() }
            }
            Button("Submit report", systemImage: "bubble.left") { submitReport() }
            Button("Reset navigation", systemImage: "arrow.counterclockwise", role: .destructive) {
                Task { await connection.app.navigationServices.resetNavigation() }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        .accessibilityLabel("Navigation options")
    }

    @ViewBuilder private var alerts: some View {
        if !navigation.error.isEmpty {
            Label(LocalizedStringKey(navigation.error), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("navigation-error-banner")
        }
        if !navigation.notice.isEmpty {
            HStack {
                Text(LocalizedStringKey(navigation.notice)).font(.footnote)
                Spacer()
                Button { navigation.notice = "" } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Dismiss navigation message")
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if !navigation.sendToComma, !navigation.locationMessage.isEmpty {
            Button(navigation.locationMessage) { navigation.requestLocation() }.font(.footnote)
        }
        if navigation.usingComma, !navigation.commaFeedMessage.isEmpty {
            Text(LocalizedStringKey(navigation.commaFeedMessage)).font(.footnote)
            if !connection.connected { Button("Reconnect to comma", action: openSettings).font(.footnote.weight(.semibold)) }
        }
        if !navigation.navigating, !saved.message.isEmpty {
            Text(LocalizedStringKey(saved.message)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func finishSearch() {
        searchFocused = false; searchingPlaces = false; query = ""
        navigation.cancelPlaceSearch()
    }

    private func startAuxiliary(_ purpose: PlaceSearchPurpose) {
        finishSearch()
        auxiliarySearch = purpose
    }

    private func select(_ place: NavigationPlace) {
        guard !navigation.busy, !navigation.navigating else { return }
        finishSearch()
        collapsed = false; expanded = false; details = false
        saved.rememberDestination(place)
        Task { await navigation.select(place) }
    }
}

private struct DuoMapGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

private struct DuoRouteButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .accessibilityHidden(true)
            configuration.label
        }
        .font(.headline).foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(StarPilotTheme.guidance.gradient, in: RoundedRectangle(cornerRadius: 15))
        .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.55)
    }
}
