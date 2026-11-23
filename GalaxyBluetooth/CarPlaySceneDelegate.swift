import CarPlay
import UIKit
import SwiftUI
import CoreFoundation
import CoreText
import MapKit
import Combine

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate, CPSessionConfigurationDelegate, CPMapTemplateDelegate {
    private final class GridAction: NSObject {
        var perform: @MainActor () -> Void
        var signature: String
        init(signature: String, perform: @escaping @MainActor () -> Void) {
            self.signature = signature; self.perform = perform
        }
    }
    private let gridActions = NSMapTable<CPGridButton, GridAction>.weakToStrongObjects()
    private final class WeakGrid {
        weak var page: CPGridTemplate?
        init(_ page: CPGridTemplate) { self.page = page }
    }
    private var sessionConfiguration: CPSessionConfiguration?
    private var controller: CPInterfaceController?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var settingsRead: Task<Void, Never>?
    private var lastSettingsRead = Date.distantPast
    private var overview: CPGridTemplate?
    private var temperatures: CPGridTemplate?
    private var rates: CPGridTemplate?
    private var toggles: CPListTemplate?
    private var catalog: [[String: Any]] = []
    private var values: [String: Any] = [:]
    private var valuesSession = ""
    private var valuesAt = Date.distantPast
    private var categoryPage = 0
    private var busy = false
    private var navigating = false
    private final class GridRefresh: NSObject {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    }
    private let settingsRefresh = NSMapTable<CPGridTemplate, GridRefresh>.weakToStrongObjects()
    private let overflowParents = NSMapTable<CPTemplate, CPTemplate>.weakToStrongObjects()
    private let gridSizes = NSMapTable<CPGridTemplate, NSNumber>.weakToStrongObjects()
    private final class MetricPageState {
        let title: String
        let kind: String
        var index = 0
        init(title: String, kind: String) { self.title = title; self.kind = kind }
    }

    private var window: CPWindow?
    private var mapController: CompanionCarPlayMap?
    private var mapTemplate: CPMapTemplate?
    private var navigationTabs: CPTabBarTemplate?
    private var navigationMenu: CPListTemplate?
    private enum NavigationAction: Equatable {
        case info, map, start(UUID), phoneTrip(UUID), directions, phone, place(SavedPlace)
    }
    private struct NavigationRow: Equatable {
        let title: String
        let detail: String
        let icon: String
        let action: NavigationAction
    }
    private var navigationRows: [NavigationRow] = []
    private var presentedDestination: UUID?
    private var tabsReady = false
    private var navigationSession: CPNavigationSession?
    private var trip: CPTrip?
    private var tripDestination = ""
    private var maneuver: CPManeuver?
    private var subscriptions = Set<AnyCancellable>()
    private var alphaMode: Bool?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        self.window = window
        connect(interfaceController)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        connect(interfaceController)
    }

    private func connect(_ interfaceController: CPInterfaceController) {
        guard controller !== interfaceController else { return }
        controller = interfaceController
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        let model = AppModel.shared
        model.setCarPlayActive(true)
        model.$navigationEnabled
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.configureMode() }
            .store(in: &subscriptions)
        model.navigationServices.navigation.$navigating.removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshNavigation() }
            .store(in: &subscriptions)
        configureMode()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTelemetry()
                self?.refreshNavigation()
                self?.refreshVisibleSettings()
            }
        }
    }

    private func configureMode() {
        guard let controller else { return }
        let model = AppModel.shared
        let alpha = model.navigationEnabled
        guard alphaMode != alpha else { return }
        alphaMode = alpha
        presentedDestination = nil
        tabsReady = false
        settingsRead?.cancel()
        settingsRead = nil
        stopGuidance()
        model.navigationServices.setEnabled(alpha)
        model.navigationServices.setCarPlayActive(alpha)
        overview = nil; temperatures = nil; rates = nil; toggles = nil
        navigating = false
        refreshTelemetry()
        mapController = nil; mapTemplate = nil
        navigationMenu = nil; navigationTabs = nil; navigationRows = []
        window?.rootViewController = UIViewController()
        catalog = localCatalogue()
        let settings = CPListTemplate(title: localizedCarPlay("Toggles"), sections: [])
        toggles = settings
        settings.tabTitle = localizedCarPlay("Toggles")
        settings.tabImage = UIImage(systemName: "switch.2")
        guard let overview, let temperatures, let rates else { return }
        var pages: [CPTemplate] = [overview, temperatures, rates, settings]
        let tabs = CPTabBarTemplate(templates: pages)
        tabs.delegate = self
        if alpha {
            let menu = CPListTemplate(title: localizedCarPlay("Navigation"), sections: [])
            navigationTabs = tabs
            navigationMenu = menu
            refreshNavigationMenu()
            if pages.count < CPTabBarTemplate.maximumTabCount {
                menu.tabTitle = localizedCarPlay("Navigation")
                menu.tabImage = UIImage(systemName: "map")
                pages.append(menu)
                tabs.updateTemplates(pages)
            } else {
                overview.leadingNavigationBarButtons = [CPBarButton(title: localizedCarPlay("Navigation")) { [weak self] _ in
                    self?.pushTemplate(menu, animated: true, completion: nil)
                }]
            }
        }
        controller.setRootTemplate(tabs, animated: false) { [weak self, weak tabs] success, _ in
            guard let self, let tabs, self.navigationTabs === tabs else { return }
            self.tabsReady = success
            if success { self.refreshNavigation() }
        }
        showCategories()
    }

    private func openNavigation() {
        guard tabsReady, let controller, window != nil, mapTemplate == nil, AppModel.shared.navigationEnabled else { return }
        let map = CompanionCarPlayMap()
        mapController = map
        window?.rootViewController = map
        let template = CPMapTemplate()
        template.guidanceBackgroundColor = StarPilotTheme.uiGuidance
        template.mapDelegate = self
        template.automaticallyHidesNavigationBar = true
        template.hidesButtonsWithNavigationBar = false
        template.leadingNavigationBarButtons = [CPBarButton(image: UIImage(systemName: "chevron.backward")!) { [weak self] _ in
            self?.returnFromMap()
        }]
        let routeImage = UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath") ?? UIImage(systemName: "map")
        let overview = CPMapButton { [weak map] button in
            guard let map else { return }
            map.showingOverview.toggle()
            button.image = map.showingOverview ? UIImage(systemName: "location.fill") : routeImage
            map.update(AppModel.shared.navigationServices.navigation)
        }
        overview.image = routeImage
        let zoomButtons = [("plus", 0.7), ("minus", 1 / 0.7)].map { symbol, factor in
            let button = CPMapButton { [weak map] _ in
                guard let map else { return }
                map.showingOverview = false
                overview.image = routeImage
                map.zoom(by: factor)
                map.update(AppModel.shared.navigationServices.navigation)
            }
            button.image = UIImage(systemName: symbol)
            return button
        }
        template.mapButtons = [overview] + zoomButtons
        presentedDestination = AppModel.shared.navigationServices.navigation.destination?.id
        mapTemplate = template
        controller.setRootTemplate(template, animated: false) { [weak self, weak template] success, _ in
            guard let self, let template, self.mapTemplate === template else { return }
            if success { self.refreshNavigation() }
            else { self.returnFromMap() }
        }
    }

    private func returnFromMap() {
        guard let tabs = navigationTabs else { return }
        stopGuidance()
        mapTemplate = nil; mapController = nil
        window?.rootViewController = UIViewController()
        tabsReady = false
        controller?.setRootTemplate(tabs, animated: false) { [weak self, weak tabs] success, _ in
            guard let self, let tabs, self.navigationTabs === tabs else { return }
            self.tabsReady = success
        }
    }

    private func refreshNavigationMenu() {
        guard let menu = navigationMenu else { return }
        let services = AppModel.shared.navigationServices
        let nav = services.navigation
        var rows: [NavigationRow] = []
        if let destination = nav.destination {
            if nav.navigating {
                let detail = nav.usingComma && !nav.commaFeedReady ? nav.commaFeedMessage :
                    (nav.instruction.isEmpty ? "Following route" : nav.instruction)
                rows.append(.init(title: destination.name, detail: detail, icon: "map.fill", action: window == nil ? .info : .map))
            } else {
                let detail = nav.busy ? (nav.sendToComma ? "Sending destination…" : "Getting directions…") : destination.address
                rows.append(.init(title: destination.name, detail: detail, icon: "mappin.circle.fill", action: .info))
                if !nav.busy {
                    if nav.phoneTripPreferred {
                        if !services.connection.connected {
                            rows.append(.init(title: "Connect to your comma", detail: "Required to start the iPhone route", icon: "car.fill", action: .info))
                        } else if nav.route == nil {
                            rows.append(.init(title: "Get directions", detail: "Calculate the iPhone route", icon: "map", action: .directions))
                        } else if nav.route?.commaPreview == nil || nav.plannedStart != nil {
                            rows.append(.init(title: "Route unavailable for handoff", detail: "Choose a shorter trip from your current location", icon: "map", action: .info))
                        } else {
                            rows.append(.init(title: "Start Route", detail: "Use the selected iPhone route on comma", icon: "car.fill", action: .phoneTrip(destination.id)))
                        }
                    } else if nav.sendToComma && !services.connection.connected {
                        rows.append(.init(title: "Get iPhone directions", detail: "Comma is disconnected", icon: "iphone", action: .phone))
                    } else if !nav.sendToComma && nav.route == nil {
                        rows.append(.init(title: "Get directions", detail: "Preview the route on iPhone", icon: "arrow.triangle.turn.up.right.diamond", action: .directions))
                    } else {
                        rows.append(.init(title: nav.sendToComma ? "Send to comma" : "Start on iPhone",
                                          detail: nav.sendToComma ? "Comma calculates the route" : destination.name,
                                          icon: "location.fill", action: .start(destination.id)))
                    }
                }
            }
            if !nav.error.isEmpty {
                rows.append(.init(title: "Navigation update", detail: nav.error, icon: "exclamationmark.circle", action: .info))
            }
        }
        if !nav.navigating && !nav.busy {
            let saved = services.saved
            let favorites = saved.library.places
            let recent = saved.recentDestinations.filter { place in
                !favorites.contains { $0.matches(latitude: place.latitude, longitude: place.longitude) }
            }
            for place in (favorites + recent).prefix(8) {
                let icon = place.kind == .home ? "house.fill" : place.kind == .work ? "briefcase.fill" :
                    (favorites.contains(place) ? "star.fill" : "clock")
                rows.append(.init(title: place.name, detail: place.address, icon: icon, action: .place(place)))
            }
            if rows.isEmpty {
                rows.append(.init(title: "Choose a destination", detail: "Search in Nav on iPhone. Saved and recent places appear here.", icon: "magnifyingglass", action: .info))
            }
        }
        guard rows != navigationRows else { return }
        navigationRows = rows
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.detail, image: UIImage(systemName: row.icon))
            if row.action != .info {
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self, weak menu] _, completion in
                    defer { completion() }
                    guard let self, let menu, self.navigationMenu === menu else { return }
                    self.refreshNavigationMenu()
                    guard self.navigationRows.contains(row) else { return }
                    switch row.action {
                    case .info: break
                    case .map:
                        self.openNavigation()
                    case .start(let destinationID), .phoneTrip(let destinationID):
                        Task { @MainActor in
                            guard nav.destination?.id == destinationID else { return }
                            let handoff = row.action == .phoneTrip(destinationID)
                            if handoff {
                                guard !nav.sendToComma, services.connection.connected, nav.plannedStart == nil,
                                      UserDefaults.standard.bool(forKey: "navigation.offerPhoneTrip"), nav.route?.commaPreview != nil else { return }
                            }
                            await nav.start(connection: services.connection, phoneRouteOnComma: handoff)
                            self.refreshNavigation()
                        }
                    case .directions:
                        Task { await nav.calculateRoutes(refresh: false) }
                    case .phone:
                        Task { await nav.selectGuidanceSource(comma: false) }
                    case .place(let saved):
                        let place = services.saved.navigationPlace(saved)
                        Task {
                            guard !nav.busy, !nav.navigating else { return }
                            services.saved.rememberDestination(place)
                            await nav.select(place)
                            self.refreshNavigationMenu()
                        }
                    }
                }
            }
            return item
        }
        menu.updateSections([CPListSection(items: items)])
    }

    private func stopGuidance() {
        navigationSession?.cancelTrip()
        navigationSession = nil; trip = nil; maneuver = nil; tripDestination = ""
    }

    private func refreshNavigation() {
        refreshNavigationMenu()
        guard AppModel.shared.navigationEnabled else { return }
        let nav = AppModel.shared.navigationServices.navigation
        if !nav.navigating {
            presentedDestination = nil
        } else if let id = nav.destination?.id {
            if mapTemplate != nil { presentedDestination = id }
            else if presentedDestination != id, controller?.presentedTemplate == nil, !navigating, !busy {
                openNavigation()
                return
            }
        }
        guard let template = mapTemplate, controller?.rootTemplate === template else { return }
        nav.checkCommaFreshness()
        mapController?.update(nav)
        let status: String? = !nav.navigating ? "Trip ended" :
            nav.reroutingPhoneTrip && !nav.commaFeedReady ? "Rerouting…" :
            nav.usingComma && !nav.commaFeedReady ? "Waiting for comma" :
            (nav.usingComma ? nav.commaPosition == nil : nav.goodLocation == nil) ? "Waiting for GPS" : nil
        if template.trailingNavigationBarButtons.first?.title != status {
            template.trailingNavigationBarButtons = status.map { title in
                [CPBarButton(title: title) { [weak self] _ in
                    self?.returnFromMap()
                }]
            } ?? []
        }
        guard nav.navigating, let destination = nav.destination else {
            stopGuidance()
            return
        }
        let key = "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"
        guard nav.usingComma ? nav.commaFeedReady : nav.goodLocation != nil else {
            if tripDestination != key { stopGuidance() }
            else if maneuver != nil {
                navigationSession?.upcomingManeuvers = []
                maneuver = nil
            }
            return
        }
        if tripDestination != key || navigationSession == nil {
            stopGuidance()
            let origin = nav.usingComma ? nav.commaPosition : nav.goodLocation?.coordinate
            guard let origin else { return }
            let choice = CPRouteChoice(summaryVariants: [destination.name], additionalInformationVariants: [], selectionSummaryVariants: [destination.name])
            let newTrip = CPTrip(origin: MKMapItem(placemark: MKPlacemark(coordinate: origin)), destination: destination.item, routeChoices: [choice])
            trip = newTrip; tripDestination = key
            navigationSession = template.startNavigationSession(for: newTrip)
        }
        guard let trip, let navigationSession else { return }
        let distance = max(0, nav.remainingDistance.isFinite ? nav.remainingDistance : 0)
        let duration = max(0, nav.remainingTime.isFinite ? nav.remainingTime : 0)
        template.updateEstimates(travelEstimates(meters: distance, seconds: duration), for: trip)
        let lines = nav.instruction.split(whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first {
            let variants = lines.count > 1 ? [lines.joined(separator: " · "), first] : [first]
            let turn = (nav.usingComma ? nav.commaManeuverType + " " + nav.commaManeuverModifier : nav.instruction).lowercased()
            let turnDistance = max(0, nav.distanceToTurn.isFinite ? nav.distanceToTurn : 0)
            let estimates = travelEstimates(meters: turnDistance, seconds: 0)
            if maneuver?.instructionVariants != variants || maneuver?.userInfo as? String != turn {
                let next = CPManeuver()
                next.userInfo = turn
                next.instructionVariants = variants
                next.dashboardInstructionVariants = variants
                next.initialTravelEstimates = estimates
                let symbol = turn.contains("roundabout") ? "arrow.triangle.2.circlepath" :
                    turn.contains("u-turn") ? "arrow.uturn.down" :
                    turn.contains("left") ? "arrow.turn.up.left" :
                    turn.contains("right") ? "arrow.turn.up.right" : "arrow.up"
                next.symbolImage = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold))
                next.dashboardSymbolImage = next.symbolImage
                if #available(iOS 17.4, *) { navigationSession.add([next]) }
                maneuver = next
                navigationSession.upcomingManeuvers = [next]
            }
            if let maneuver {
                navigationSession.updateEstimates(estimates, for: maneuver)
            }
        } else {
            navigationSession.upcomingManeuvers = []
            maneuver = nil
        }
    }

    private func travelEstimates(meters: Double, seconds: Double) -> CPTravelEstimates {
        let units = NavigationDistanceUnits(rawValue: UserDefaults.standard.string(forKey: NavigationDistanceUnits.key) ?? "") ?? .system
        let display = units.measurement(meters)
        if #available(iOS 17.4, *) {
            return CPTravelEstimates(distanceRemaining: display, distanceRemainingToDisplay: display, timeRemaining: seconds)
        }
        return CPTravelEstimates(distanceRemaining: display, timeRemaining: seconds)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        let services = AppModel.shared.navigationServices
        Task { await services.navigation.end(connection: services.connection) }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController, from window: CPWindow) {
        disconnect()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        disconnect()
    }

    private func disconnect() {
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        work?.cancel(); work = nil
        settingsRead?.cancel(); settingsRead = nil
        stopGuidance()
        window?.rootViewController = nil; window = nil; mapController = nil; mapTemplate = nil; alphaMode = nil
        navigationMenu = nil; navigationTabs = nil; navigationRows = []
        controller = nil
        sessionConfiguration?.delegate = nil; sessionConfiguration = nil
        overview = nil; temperatures = nil; rates = nil; toggles = nil
        catalog = []; values = [:]; busy = false; categoryPage = 0; valuesSession = ""; valuesAt = .distantPast
        gridActions.removeAllObjects(); gridSizes.removeAllObjects(); overflowParents.removeAllObjects(); settingsRefresh.removeAllObjects(); navigating = false
        AppModel.shared.navigationServices.setCarPlayActive(false)
        AppModel.shared.setCarPlayActive(false)
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === toggles { loadGalaxy() }
    }

    private var carAppearance: UIUserInterfaceStyle {
        if let style = sessionConfiguration?.contentStyle {
            if style.contains(.dark) && !style.contains(.light) { return .dark }
            if style.contains(.light) && !style.contains(.dark) { return .light }
        }
        return controller?.carTraitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle) {
        let appearance: UIUserInterfaceStyle = contentStyle.contains(.dark) && !contentStyle.contains(.light) ? .dark :
            contentStyle.contains(.light) && !contentStyle.contains(.dark) ? .light : carAppearance
        let traits = UITraitCollection(userInterfaceStyle: appearance)
        let templates = controller?.templates ?? []
        var visited = Set<ObjectIdentifier>()
        for template in templates.flatMap({ ($0 as? CPTabBarTemplate)?.templates ?? [$0] }) {
            guard let grid = template as? CPGridTemplate, visited.insert(ObjectIdentifier(grid)).inserted else { continue }
            for button in grid.gridButtons {
                if #available(iOS 26.0, *), let asset = button.image.imageAsset { button.updateImage(asset.image(with: traits)) }
            }
        }
    }

    private func pushTemplate(_ template: CPTemplate, animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        guard let controller, !navigating else { completion?(false, nil); return }
        navigating = true
        let finished: (Bool, Error?) -> Void = { [weak self, weak controller] success, error in
            guard let self, let controller, self.controller === controller else { return }
            self.navigating = false
            completion?(success, error)
            if !success { self.notice(error?.localizedDescription ?? "This page could not be opened.") }
        }
        // A tab container also occupies a hierarchy level. Reserve that level before pushing.
        if controller.templates.count >= 4, let parent = controller.topTemplate {
            controller.popTemplate(animated: false) { [weak self, weak controller] success, error in
                guard let self, let controller, self.controller === controller else { return }
                guard success else { finished(false, error); return }
                self.overflowParents.setObject(parent, forKey: template)
                if let page = template as? CPBarButtonProviding {
                    page.backButton = CPBarButton(image: UIImage(systemName: "chevron.left")!) { [weak self] _ in
                        self?.popTemplate(animated: true, completion: nil)
                    }
                }
                controller.pushTemplate(template, animated: animated, completion: finished)
            }
        } else {
            controller.pushTemplate(template, animated: animated, completion: finished)
        }
    }

    private func popTemplate(animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        guard let controller, !navigating else { completion?(false, nil); return }
        let top = controller.topTemplate
        let parent = top.flatMap { overflowParents.object(forKey: $0) }
        navigating = true
        controller.popTemplate(animated: animated) { [weak self, weak controller] success, error in
            guard let self, let controller, self.controller === controller else { return }
            guard success else { self.navigating = false; completion?(false, error); return }
            if let top { self.overflowParents.removeObject(forKey: top) }
            if let parent {
                controller.pushTemplate(parent, animated: false) { [weak self] restored, error in
                    self?.navigating = false; completion?(restored, error)
                }
            } else {
                self.navigating = false; completion?(true, nil)
            }
        }
    }

    private func paddedButtons(_ buttons: [CPGridButton], capacity: Int = 8) -> [CPGridButton] {
        var result = Array(buttons.prefix(capacity))
        while result.count < capacity {
            let empty = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            let action = GridAction(signature: "empty", perform: {})
            let spacer = CPGridButton(titleVariants: [" "], image: empty) { _ in action.perform() }
            gridActions.setObject(action, forKey: spacer)
            spacer.isEnabled = false
            result.append(spacer)
        }
        return result
    }

    private func localizedCarPlay(_ text: String) -> String {
        let language = UserDefaults.standard.string(forKey: "galaxy.app.language") ?? "en"
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return text }
        return bundle.localizedString(forKey: text, value: text, table: nil)
    }

    private func makeGrid(title: String?, gridButtons: [CPGridButton], compact: Bool = false) -> CPGridTemplate {
        let capacity = compact ? 4 : 8
        let page = CPGridTemplate(title: title.map(localizedCarPlay), gridButtons: paddedButtons(gridButtons, capacity: capacity))
        gridSizes.setObject(NSNumber(value: capacity), forKey: page)
        return page
    }

    private func grid(_ title: String, icon: String, buttons: [CPGridButton]) -> CPGridTemplate {
        precondition(!buttons.isEmpty)
        let template = makeGrid(title: title, gridButtons: buttons)
        template.tabTitle = localizedCarPlay(title)
        template.tabImage = UIImage(systemName: icon)
        return template
    }

    private func button(_ title: String, icon: String, value: String? = nil, action: @escaping @MainActor () -> Void = {}) -> CPGridButton {
        let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let symbol = UIImage(systemName: icon, withConfiguration: configuration) ?? UIImage(systemName: "circle")!
        let image: UIImage
        if let value {
            let format = UIGraphicsImageRendererFormat()
            format.scale = controller?.carTraitCollection.displayScale ?? 2
            let text = value
            let asset = UIImageAsset()
            for (style, color) in [(UIUserInterfaceStyle.light, UIColor.black), (.dark, UIColor.white)] {
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72), format: format).image { _ in
                    if value == "On" || value == "Off" {
                        let on = value == "On"
                        (on ? UIColor.systemGreen : (style == .dark ? UIColor.darkGray : UIColor.systemGray)).setFill()
                        UIBezierPath(roundedRect: CGRect(x: 3, y: 7, width: 66, height: 36), cornerRadius: 18).fill()
                        UIColor.white.setFill()
                        UIBezierPath(ovalIn: CGRect(x: on ? 36 : 6, y: 10, width: 30, height: 30)).fill()
                    } else {
                        symbol.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 22, y: 0, width: 28, height: 28))
                    }
                    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                    let preferred = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
                    let width = (text as NSString).size(withAttributes: [.font: preferred]).width
                    let size = preferred.pointSize * min(1, 70 / max(1, width))
                    (text as NSString).draw(in: CGRect(x: 0, y: value == "On" || value == "Off" ? 47 : 36, width: 72, height: 25), withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                        .foregroundColor: color, .paragraphStyle: paragraph
                    ])
                }.withRenderingMode(.alwaysOriginal)
                asset.register(rendered, with: UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style), UITraitCollection(displayScale: format.scale)
                ]))
            }
            image = asset.image(with: UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: carAppearance), UITraitCollection(displayScale: format.scale)
            ]))
        } else { image = symbol.withRenderingMode(.alwaysTemplate) }
        let label = localizedCarPlay(title)
        let state = GridAction(signature: "\(title)|\(icon)|\(value ?? "")", perform: action)
        let result = CPGridButton(titleVariants: [label, compactCaption(label)], image: image) { _ in state.perform() }
        gridActions.setObject(state, forKey: result)
        return result
    }

    private func compactCaption(_ label: String) -> String {
        label.replacingOccurrences(of: "Advanced ", with: "Adv. ")
            .replacingOccurrences(of: "Longitudinal", with: "Speed")
            .replacingOccurrences(of: "Lateral", with: "Steering")
            .replacingOccurrences(of: "Acceleration", with: "Accel.")
            .replacingOccurrences(of: "Deceleration", with: "Braking")
            .replacingOccurrences(of: "Conditional ", with: "")
            .replacingOccurrences(of: "Controller", with: "Control")
    }

    private func updateGrid(_ page: CPGridTemplate, buttons rawButtons: [CPGridButton]) {
        precondition(!rawButtons.isEmpty)
        let buttons = paddedButtons(rawButtons, capacity: gridSizes.object(forKey: page)?.intValue ?? 8)
        if #available(iOS 26.0, *), page.gridButtons.count == buttons.count {
            for (existing, replacement) in zip(page.gridButtons, buttons) {
                guard let current = gridActions.object(forKey: existing),
                      let next = gridActions.object(forKey: replacement) else {
                    page.updateGridButtons(buttons)
                    return
                }
                current.perform = next.perform
                existing.isEnabled = replacement.isEnabled
                if current.signature != next.signature {
                    existing.updateTitleVariants(replacement.titleVariants)
                    existing.updateImage(replacement.image)
                    current.signature = next.signature
                }
            }
        } else {
            page.updateGridButtons(buttons)
        }
    }

    private func telemetryGrid(_ existing: CPGridTemplate?, title: String, icon: String,
                               buttons: [CPGridButton]) -> CPGridTemplate {
        if let existing { updateGrid(existing, buttons: buttons); return existing }
        return grid(title, icon: icon, buttons: buttons)
    }

    private func external(_ metric: DiagnosticMetric) -> Bool {
        let name = metric.name.lowercased()
        return name.contains("external gpu") || name.contains("chestnut") || name.hasPrefix("sensor: amdgpu")
    }

    private func thermalGroup(_ metric: DiagnosticMetric) -> String {
        let name = metric.name.lowercased()
        if external(metric) { return "External GPU" }
        if name.hasPrefix("sensor:") { return "Other sensors" }
        if name.contains("cpu") || name.contains("dsp") || name.contains("soc") { return "Processors" }
        if name.contains("gpu") { return "Onboard GPU" }
        if name.contains("memory") { return "Memory" }
        if name.contains("intake") || name.contains("exhaust") { return "Cooling" }
        if name.contains("pmic") { return "Power" }
        if name.contains("modem") || name.contains("gnss") { return "Connectivity" }
        return "Other sensors"
    }

    private func thermalLabel(_ group: String) -> String {
        switch group {
        case "Processors": return "CPU / DSP"
        case "Onboard GPU": return "GPU"
        case "Connectivity": return "Radios"
        case "Other sensors": return "Sensors"
        default: return group
        }
    }

    private func thermalIcon(_ group: String) -> String {
        switch group {
        case "Processors", "Onboard GPU", "External GPU": return "cpu"
        case "Memory": return "memorychip"
        case "Cooling": return "fan"
        case "Power": return "bolt"
        case "Connectivity": return "antenna.radiowaves.left.and.right"
        default: return "thermometer.medium"
        }
    }

    private func maximum(_ metrics: [DiagnosticMetric]) -> String {
        guard let value = metrics.compactMap(\.value).filter(\.isFinite).max() else { return "—" }
        return String(format: "%.1f °C", value)
    }

    private func refreshTelemetry() {
        let model = AppModel.shared
        let system = model.diagnostics.fresh ? model.diagnostics.system ?? [:] : [:]
        let memory = system["memory"] as? [String: Any] ?? [:]
        let storage = system["storage"] as? [String: Any] ?? [:]
        func value(_ source: [String: Any], _ key: String, _ unit: String) -> String {
            guard let number = source[key] as? NSNumber, number.doubleValue.isFinite else { return "—" }
            let amount = number.doubleValue.formatted(.number.precision(.fractionLength(0...1)))
            switch unit {
            case "": return amount
            case "%": return amount + "%"
            default: return amount + " " + unit
            }
        }
        overview = telemetryGrid(overview, title: "Overview", icon: "sparkles", buttons: [
            button(model.transport.label, icon: "antenna.radiowaves.left.and.right"),
            button("CPU", icon: "cpu", value: value(system, "cpuPercent", "%")),
            button("Memory", icon: "memorychip", value: value(memory, "percent", "%")),
            button("Storage used", icon: "internaldrive", value: value(storage, "usedGiB", "GiB")),
            button("Uptime", icon: "clock", value: value(system, "uptimeSeconds", "s")),
            button("Processes", icon: "list.bullet", value: value(system, "processCount", ""))
        ])
        let cores = system["cores"] as? [[String: Any]] ?? []
        rates = telemetryGrid(rates, title: "CPU", icon: "cpu", buttons: cores.isEmpty ? [button("Waiting for CPU readings", icon: "cpu")] : cores.prefix(8).map {
            button($0["name"] as? String ?? "CPU", icon: "cpu", value: value($0, "percent", "%"))
        })
        temperatures = telemetryGrid(temperatures, title: "Memory", icon: "memorychip", buttons: [
            button("Used", icon: "memorychip", value: value(memory, "usedMiB", "MiB")),
            button("Available", icon: "memorychip", value: value(memory, "availableMiB", "MiB")),
            button("Total", icon: "memorychip", value: value(memory, "totalMiB", "MiB")),
            button("Storage total", icon: "internaldrive", value: value(storage, "totalGiB", "GiB"))
        ])
    }

    private func rateGroup(_ metric: DiagnosticMetric) -> String {
        let name = metric.name.lowercased()
        if external(metric) { return "external" }
        if name.contains("camera") { return "cameras" }
        if name.contains("model") || name.contains("plan") { return "models" }
        if name.contains("carstate") || name.contains("carcontrol") || name.contains("selfdrive") { return "driving" }
        if name == "ui" { return "display" }
        return "other"
    }

    private func showMetrics(_ title: String, kind: String) {
        guard controller != nil else { return }
        let page = makeGrid(title: title, gridButtons: [button("Loading readings…", icon: "hourglass")])
        page.userInfo = MetricPageState(title: title, kind: kind)
        updateMetrics(page)
        pushTemplate(page, animated: true, completion: nil)
    }

    private func updateMetrics(_ page: CPGridTemplate) {
        guard let state = page.userInfo as? MetricPageState else { return }
        let diagnostics = AppModel.shared.diagnostics
        guard diagnostics.fresh, let sample = diagnostics.snapshot else {
            updateGrid(page, buttons: [button("Telemetry unavailable", icon: "exclamationmark.triangle") { [weak self] in self?.notice(diagnostics.status) }])
            return
        }
        let readings = sample.temperatures.filter { thermalGroup($0) == state.kind } + sample.rates.filter { rateGroup($0) == state.kind }
        let count = max(1, (readings.count + 7) / 8)
        state.index = min(state.index, count - 1)
        var buttons = readings.dropFirst(state.index * 8).prefix(8).map { button($0.name, icon: "gauge", value: $0.display) }
        if buttons.isEmpty { buttons = [button("No readings available", icon: "questionmark.circle")] }
        paging(page, index: state.index, count: count) { [weak self, weak page] index in
            guard let self, let page else { return }; state.index = index; self.updateMetrics(page)
        }
        page.updateTitle(count > 1 ? "\(state.title) · \(state.index + 1)/\(count)" : state.title)
        updateGrid(page, buttons: buttons)
    }

    private final class SettingsPageState {
        let name: String
        var snapshot: [String: Any] = [:]
        var session = ""
        var index = 0
        init(_ name: String) { self.name = name }

        func update(_ next: [String: Any], session nextSession: String) -> Bool {
            let previousRows = snapshot["rows"] as? NSArray
            let changed = session != nextSession || previousRows?.isEqual(next["rows"]) != true
            // Even identical rows come with a fresh view token for the next edit.
            snapshot = next
            session = nextSession
            return changed
        }
    }
    private struct NumericAdjustment {
        let minimum: Double
        let maximum: Double
        let step: Double
        var value: Double

        init?(_ row: [String: Any]) {
            guard let value = Double(String(describing: row["value"] ?? "")), value.isFinite,
                  let minimum = (row["minimum"] as? NSNumber)?.doubleValue, minimum.isFinite,
                  let maximum = (row["maximum"] as? NSNumber)?.doubleValue, maximum.isFinite,
                  minimum <= value, value <= maximum,
                  let step = (row["step"] as? NSNumber)?.doubleValue, step.isFinite, step > 0,
                  (row["choices"] as? [String] ?? []).isEmpty,
                  row["confirm"] as? Bool != true,
                  (row["repairValue"] as? String ?? "").isEmpty else { return nil }
            self.minimum = minimum
            self.maximum = maximum
            self.step = step
            self.value = value
        }

        mutating func move(_ direction: Int) {
            let last = floor((maximum - minimum) / step + 1e-9)
            let index = min(last, max(0, ((value - minimum) / step).rounded() + Double(direction)))
            value = min(maximum, max(minimum, ((minimum + index * step) * 1e8).rounded() / 1e8))
        }
    }

    private final class SettingsEditorState {
        let parent: CPListTemplate
        let index: Int
        let label: String
        var page = 0
        var adjustment: NumericAdjustment?
        var lastTap = TimeInterval.zero
        weak var valueItem: CPListItem?
        init(parent: CPListTemplate, index: Int, label: String) {
            self.parent = parent
            self.index = index
            self.label = label
        }
    }
    private var session: String {
        let model = AppModel.shared
        return model.connectionSession
    }
    private func request(_ path: String, payload: [String: Any]? = nil) async throws -> [String: Any] {
        let original = session
        let response = try await AppModel.shared.transport.request(path: path, method: payload == nil ? "GET" : "POST",
            headers: payload == nil ? [:] : ["Content-Type": "application/json"],
            body: try payload.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
        try Task.checkCancellation()
        guard original == session else { throw BridgeError.message("Connection changed. Refresh the page.") }
        let data = (try? JSONSerialization.jsonObject(with: response.bodyData)) as? [String: Any] ?? [:]
        guard response.status == 200 else {
            throw BridgeError.message(data["error"] as? String ?? "Galaxy request failed (HTTP \(response.status)).")
        }
        return data
    }
    private func localCatalogue() -> [[String: Any]] { [] }
    private func categoryButtons() -> [CPGridButton] {
        [button("Open toggles", icon: "switch.2") { [weak self] in self?.loadGalaxy() }]
    }
    private func showCategories() { loadGalaxy() }
    private func loadGalaxy() {
        guard let toggles else { return }
        if toggles.userInfo == nil { toggles.userInfo = SettingsPageState("hub") }
        loadSettings(toggles)
    }
    private func settingsItem(_ title: String, detail: String? = nil, icon: String,
                              enabled: Bool = true, action: @escaping @MainActor () -> Void = {}) -> CPListItem {
        let image = UIImage(systemName: icon) ?? UIImage(systemName: "slider.horizontal.3")
        let item = CPListItem(text: localizedCarPlay(title), detailText: detail, image: image)
        item.isEnabled = enabled
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    private func openSettings(_ name: String, title: String) {
        let loading = settingsItem("Loading…", icon: "hourglass", enabled: false)
        let page = CPListTemplate(title: localizedCarPlay(title), sections: [CPListSection(items: [loading])])
        page.userInfo = SettingsPageState(name)
        pushTemplate(page, animated: true) { [weak self, weak page] success, _ in
            if success, let page { self?.loadSettings(page) }
        }
    }
    private var visibleSettingsList: CPListTemplate? {
        let top = controller?.topTemplate
        return ((top as? CPTabBarTemplate)?.selectedTemplate ?? top) as? CPListTemplate
    }

    private func refreshVisibleSettings() {
        guard settingsRead == nil, !busy, !navigating, controller?.presentedTemplate == nil,
              AppModel.shared.transport.connected, Date().timeIntervalSince(lastSettingsRead) >= 3,
              let visible = visibleSettingsList else { return }
        let parent = (visible.userInfo as? SettingsEditorState)?.parent ?? visible
        guard parent.userInfo is SettingsPageState else { return }
        loadSettings(parent, refreshing: visible)
    }

    private func loadSettings(_ page: CPListTemplate, refreshing visible: CPListTemplate? = nil) {
        guard let state = page.userInfo as? SettingsPageState, !busy else { return }
        settingsRead?.cancel()
        lastSettingsRead = Date()
        settingsRead = Task { [weak self, weak page] in
            guard let self, let page else { return }
            defer { if !Task.isCancelled { self.settingsRead = nil } }
            do {
                let snapshot = try await self.settingsSnapshot(state)
                try Task.checkCancellation()
                if let visible, (self.visibleSettingsList !== visible || self.busy || self.controller?.presentedTemplate != nil) { return }
                let changed = state.update(snapshot, session: self.session)
                guard changed || visible == nil else { return }
                self.drawSettings(page)
                if let visible, let editor = visible.userInfo as? SettingsEditorState {
                    let rows = snapshot["rows"] as? [[String: Any]] ?? []
                    guard rows.indices.contains(editor.index), let label = rows[editor.index]["label"] as? String,
                          label == editor.label, rows[editor.index]["action"] as? Bool == true,
                          rows[editor.index]["available"] as? Bool == true else {
                        self.popTemplate(animated: true, completion: nil)
                        return
                    }
                    self.drawEditor(visible, state: editor, row: rows[editor.index])
                }
            } catch {
                if visible == nil && !Task.isCancelled {
                    state.snapshot = [:]
                    page.updateSections([CPListSection(items: [self.settingsItem("Retry", icon: "arrow.clockwise") { [weak self, weak page] in
                        if let page { self?.loadSettings(page) }
                    }])])
                    self.notice(error.localizedDescription)
                }
            }
        }
    }
    private func settingsSnapshot(_ state: SettingsPageState) async throws -> [String: Any] {
        let name = state.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))!
        return try await request("/api/settings/pages/" + name)
    }
    private static let categoryIcons = [
        "vehicle": "car.fill", "lane": "road.lanes", "lane_change": "arrow.left.arrow.right",
        "profiles": "slider.horizontal.3", "personalities": "person.2.fill", "slc": "speedometer",
        "localization": "globe", "developer": "chevron.left.forwardslash.chevron.right",
        "sounds": "speaker.wave.2.fill", "driving_options": "car.2.fill", "aol": "steeringwheel",
        "wheel": "steeringwheel", "curve": "arrow.triangle.turn.up.right.circle",
        "torque": "dial.medium", "tuning": "slider.horizontal.3", "bluepilot": "dial.medium",
        "conditional": "arrow.triangle.branch", "cem": "arrow.triangle.branch",
        "traffic": "car.2.fill", "aggressive": "hare.fill", "standard": "gauge", "relaxed": "tortoise.fill",
        "acceleration": "speedometer", "braking": "minus.circle", "following": "car.2.fill",
        "appearance": "paintpalette.fill", "display": "sun.max.fill", "pip": "pip",
        "sentry": "shield.fill", "vasm": "camera.viewfinder", "data": "arrow.up.arrow.down",
        "power": "bolt.fill", "starport_options": "rectangle.connected.to.line.below",
        "resets": "arrow.counterclockwise"
    ]
    private static let toggleIcons = [
        "Enhanced Stops": "stop.circle", "Always Hold Enhanced Stops": "stop.circle",
        "Faster Takeoffs": "hare.fill", "Pause while following a lead": "pause.circle",
        "Show Curve status": "eye", "Curve Speed Controller": "arrow.triangle.turn.up.right.circle"
    ]

    private func settingsIcon(page: String, child: String, label: String, binary: Bool, hasChoices: Bool) -> String {
        let path = child.isEmpty ? page : child
        let category = path.split(separator: "/").last.flatMap { Self.categoryIcons[String($0)] }
        if !child.isEmpty { return category ?? "folder" }
        if let icon = Self.toggleIcons[label] { return icon }
        if binary { return category ?? "power" }
        return hasChoices ? "list.bullet" : "slider.horizontal.3"
    }

    private func isOnOffChoice(_ choices: [String]) -> Bool {
        choices.count == 2 && choices.contains("On") && choices.contains("Off")
    }

    // CarPlay owns the row and its tap target. The trailing image reflects the
    // last value read from comma, including while the user reviews a change.
    private static func switchImage(on: Bool) -> UIImage {
        let size = CGSize(width: 38, height: 22)
        // Keep the accessory canvas fixed so CarPlay preserves the clear margin.
        let track = CGRect(x: 2, y: 1, width: 34, height: 20)
        return UIGraphicsImageRenderer(size: size).image { _ in
            (on ? UIColor.systemGreen : UIColor.systemGray).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: track.height / 2).fill()
            let inner = track.insetBy(dx: 1, dy: 1)
            let thumb = CGRect(x: on ? inner.maxX - inner.height : inner.minX, y: inner.minY,
                               width: inner.height, height: inner.height)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: thumb).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
    private static let onImage = switchImage(on: true)
    private static let offImage = switchImage(on: false)


    private func displayedSettingValue(_ row: [String: Any]) -> String? {
        guard let raw = row["value"], !(raw is NSNull) else { return nil }
        let text = String(describing: raw)
        guard let number = Double(text), number.isFinite else { return localizedCarPlay(text) }
        if row["displayScale"] as? String == "lane-strength",
           let minimum = (row["minimum"] as? NSNumber)?.doubleValue, minimum < 100,
           let maximum = (row["maximum"] as? NSNumber)?.doubleValue, maximum > 100 {
            // Galaxy displays the saved neutral value (100) as 5 on its 1–10 scale.
            let strength = number <= 100 ? 1 + 4 * (number - minimum) / (100 - minimum)
                                         : 5 + 5 * (number - 100) / (maximum - 100)
            return strength.formatted(.number.precision(.fractionLength(0...2)))
        }
        guard let unit = row["unit"] as? String, !unit.isEmpty else { return text }
        return text + (unit == "%" ? "" : " ") + unit
    }

    private func drawSettings(_ page: CPListTemplate) {
        guard let state = page.userInfo as? SettingsPageState else { return }
        let rows = state.snapshot["rows"] as? [[String: Any]] ?? []
        let capacity = max(1, CPListTemplate.maximumItemCount)
        let count = max(1, (rows.count + capacity - 1) / capacity)
        state.index = min(state.index, count - 1)
        let start = state.index * capacity
        let items = (start..<min(rows.count, start + capacity)).map { index -> CPListTemplateItem in
            let row = rows[index]
            let child = row["page"] as? String ?? ""
            let value = row["value"].flatMap { $0 is NSNull ? nil : String(describing: $0) }
            let choices = row["choices"] as? [String] ?? []
            let binary = child.isEmpty && isOnOffChoice(choices) && (value == "On" || value == "Off")
            let label = row["label"] as? String ?? "Setting"
            let icon = settingsIcon(page: state.name, child: child, label: label, binary: binary, hasChoices: !choices.isEmpty)
            let enabled = row["available"] as? Bool == true && (!child.isEmpty || row["action"] as? Bool == true) && !busy
            let description = (row["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if binary {
                let detail = [value, description].compactMap { $0 }.filter { !$0.isEmpty }
                    .map(localizedCarPlay).joined(separator: " · ")
                let item = settingsItem(label, detail: detail, icon: icon, enabled: enabled) { [weak self, weak page] in
                    guard let self, let page else { return }
                    guard state.session == self.session,
                          let latest = state.snapshot["rows"] as? [[String: Any]], latest.indices.contains(index),
                          (latest[index] as NSDictionary).isEqual(row) else { self.loadSettings(page); return }
                    self.preview(page, index: index, selection: value == "On" ? "Off" : "On", detailRow: row)
                }
                item.setAccessoryImage(value == "On" ? Self.onImage : Self.offImage)
                return item
            }
            let detail = [child.isEmpty ? displayedSettingValue(row) : nil, description.map(localizedCarPlay)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let item = settingsItem(label, detail: detail.isEmpty ? nil : detail,
                                    icon: icon, enabled: enabled) { [weak self, weak page] in
                guard let self, let page else { return }
                guard state.session == self.session else { self.loadSettings(page); return }
                if !child.isEmpty { self.openSettings(child, title: row["label"] as? String ?? "Toggles") }
                else { self.editSetting(page, index: index, row: row) }
            }
            if enabled {
                item.accessoryType = .disclosureIndicator
            }
            return item
        }
        page.updateSections([CPListSection(items: items.isEmpty ? [settingsItem("No settings available", icon: "info.circle", enabled: false)] : items)])
        paging(page, index: state.index, count: count) { [weak self, weak page] next in
            guard let page else { return }; state.index = next; self?.drawSettings(page)
        }
    }
    private func editSetting(_ parent: CPListTemplate, index: Int, row: [String: Any]) {
        let editor = CPListTemplate(title: row["label"] as? String, sections: [])
        let state = SettingsEditorState(parent: parent, index: index, label: row["label"] as? String ?? "")
        editor.userInfo = state
        drawEditor(editor, state: state, row: row)
        pushTemplate(editor, animated: true, completion: nil)
    }

    private func descriptionLines(_ text: NSAttributedString, width: CGFloat) -> [String] {
        let typesetter = CTTypesetterCreateWithAttributedString(text as CFAttributedString)
        let string = text.string as NSString
        var offset = 0
        var lines: [String] = []
        while offset < string.length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
            let length = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: offset).length
            let line = string.substring(with: NSRange(location: offset, length: length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            offset += length
        }
        return lines
    }

    private func descriptionItems(_ row: [String: Any]) -> [CPListItem] {
        guard let reason = row["reason"] as? String, !reason.isEmpty else { return [] }
        // CarPlay list rows have two single-line fields. Lay out the whole description
        // across rows, including on head units with a short list or a narrow screen.
        let screenWidth = window?.safeAreaLayoutGuide.layoutFrame.width ?? 0
        let width = screenWidth > 0 ? max(150, min(460, screenWidth * 0.70 - 28)) : 220
        let text = NSAttributedString(string: localizedCarPlay(reason), attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)])
        let lines = descriptionLines(text, width: width)
        return stride(from: 0, to: lines.count, by: 2).map { index in
            CPListItem(text: lines[index], detailText: index + 1 < lines.count ? lines[index + 1] : nil)
        }
    }

    private func showSettingDetails(_ row: [String: Any]) {
        let items = descriptionItems(row)
        guard !items.isEmpty else { return }
        let page = CPListTemplate(title: row["label"] as? String, sections: [])
        let capacity = max(1, CPListTemplate.maximumItemCount)
        drawDetails(page, items: items, capacity: capacity, index: 0)
        pushTemplate(page, animated: true, completion: nil)
    }

    private func drawDetails(_ page: CPListTemplate, items: [CPListItem], capacity: Int, index: Int) {
        page.updateSections([CPListSection(items: Array(items.dropFirst(index * capacity).prefix(capacity)))])
        paging(page, index: index, count: (items.count + capacity - 1) / capacity) { [weak self, weak page] next in
            if let page { self?.drawDetails(page, items: items, capacity: capacity, index: next) }
        }
    }

    private func drawEditor(_ editor: CPListTemplate, state: SettingsEditorState, row: [String: Any]) {
        let parent = state.parent
        let index = state.index
        let choices = row["choices"] as? [String] ?? []
        let current = String(describing: row["value"] ?? "")
        let controls: [CPListItem]
        if !choices.isEmpty {
            controls = choices.map { choice in
                settingsItem(choice, icon: current == choice ? "checkmark.circle.fill" : "circle") { [weak self, weak parent] in
                    guard let parent else { return }
                    self?.preview(parent, index: index, selection: choice)
                }
            }
        } else if ((row["step"] as? NSNumber)?.doubleValue ?? 0) > 0 {
            controls = [(-1, "Decrease", "minus.circle"), (1, "Increase", "plus.circle")].map { direction, title, icon in
                settingsItem(title, icon: icon, enabled: row["available"] as? Bool == true && row["action"] as? Bool == true) { [weak self, weak editor, weak parent] in
                    guard let self, let editor, let parent, self.controller?.topTemplate === editor else { return }
                    if let number = NumericAdjustment(row) {
                        self.adjustNumber(direction, number: number, editor: editor, edit: state, row: row)
                    } else if !self.busy {
                        self.applyStep(direction, editor: editor, parent: parent, index: index, row: row)
                    }
                }
            }
        } else {
            controls = [
                settingsItem("Continue", icon: "checkmark.circle") { [weak self, weak parent] in
                    if let parent { self?.preview(parent, index: index) }
                }
            ]
        }
        var displayed = row
        if let number = state.adjustment { displayed["value"] = NSNumber(value: number.value).stringValue }
        let value = displayedSettingValue(displayed)
        var items = controls
        state.valueItem = nil
        if NumericAdjustment(row) != nil, let value {
            let item = CPListItem(text: value, detailText: nil)
            state.valueItem = item
            items.insert(item, at: 0)
        }
        if let reason = row["reason"] as? String, !reason.isEmpty {
            let details = settingsItem("Details", detail: localizedCarPlay(reason), icon: "info.circle") { [weak self] in
                self?.showSettingDetails(row)
            }
            details.accessoryType = .disclosureIndicator
            items.append(details)
        }
        let capacity = max(1, CPListTemplate.maximumItemCount)
        let count = (items.count + capacity - 1) / capacity
        state.page = min(state.page, count - 1)
        let visible = Array(items.dropFirst(state.page * capacity).prefix(capacity))
        editor.updateSections([CPListSection(items: visible, header: state.valueItem == nil ? value : nil, sectionIndexTitle: nil)])
        paging(editor, index: state.page, count: count) { [weak self, weak editor] next in
            guard let editor else { return }
            state.page = next
            self?.drawEditor(editor, state: state, row: row)
        }
    }

    private func adjustNumber(_ direction: Int, number: NumericAdjustment, editor: CPListTemplate,
                              edit: SettingsEditorState, row: [String: Any]) {
        guard let page = edit.parent.userInfo as? SettingsPageState, page.session == session,
              let rows = page.snapshot["rows"] as? [[String: Any]], rows.indices.contains(edit.index),
              rows[edit.index]["label"] as? String == edit.label,
              rows[edit.index]["available"] as? Bool == true, rows[edit.index]["action"] as? Bool == true,
              !busy || edit.adjustment != nil else { return }
        var target = edit.adjustment ?? number
        let previous = target.value
        target.move(direction)
        guard target.value != previous else { return }
        let firstTap = edit.adjustment == nil
        edit.adjustment = target
        edit.lastTap = ProcessInfo.processInfo.systemUptime
        var displayed = row
        displayed["value"] = NSNumber(value: target.value).stringValue
        if let value = displayedSettingValue(displayed) { edit.valueItem?.setText(value) }
        guard firstTap else { return }
        settingsRead?.cancel()
        settingsRead = nil
        busy = true
        let originalSession = session
        let attachedController = controller
        work = Task {
            do {
                while let adjustment = edit.adjustment {
                    try Task.checkCancellation()
                    guard originalSession == session, controller === attachedController,
                          let rows = page.snapshot["rows"] as? [[String: Any]], rows.indices.contains(edit.index),
                          rows[edit.index]["label"] as? String == edit.label,
                          rows[edit.index]["available"] as? Bool == true, rows[edit.index]["action"] as? Bool == true,
                          let saved = NumericAdjustment(rows[edit.index]), saved.step == adjustment.step,
                          saved.minimum == adjustment.minimum, saved.maximum == adjustment.maximum,
                          let view = page.snapshot["view"] as? String else {
                        throw BridgeError.message("Settings changed. Check the current value.")
                    }
                    if saved.value == adjustment.value {
                        edit.adjustment = nil
                        drawSettings(edit.parent)
                        if controller?.topTemplate === editor { drawEditor(editor, state: edit, row: rows[edit.index]) }
                        break
                    }
                    let delay = edit.lastTap + 0.4 - ProcessInfo.processInfo.systemUptime
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(ceil(delay * 1e9)))
                        continue
                    }
                    let pending = try await request("/api/settings/preview", payload: ["view": view, "row": edit.index, "value": adjustment.value])
                    guard let intent = pending["intent"] as? String else { throw BridgeError.message("Refresh settings and try again.") }
                    if edit.adjustment?.value != adjustment.value { continue }
                    let result = try await request("/api/settings/confirm", payload: ["intent": intent, "confirmed": true])
                    guard result["saved"] as? Bool == true else {
                        throw BridgeError.message("Save could not be confirmed. Check the current value.")
                    }
                    let snapshot = try await settingsSnapshot(page)
                    _ = page.update(snapshot, session: originalSession)
                    guard let fresh = snapshot["rows"] as? [[String: Any]], fresh.indices.contains(edit.index),
                          fresh[edit.index]["label"] as? String == edit.label,
                          NumericAdjustment(fresh[edit.index])?.value == adjustment.value else {
                        throw BridgeError.message("Settings changed. Check the current value.")
                    }
                }
                busy = false
            } catch {
                edit.adjustment = nil
                guard !Task.isCancelled, controller === attachedController else { return }
                busy = false
                let message = error.localizedDescription
                if controller?.topTemplate === editor {
                    popTemplate(animated: true) { _, _ in
                        self.loadSettings(edit.parent)
                        self.notice(message)
                    }
                } else {
                    loadSettings(edit.parent)
                    notice(message)
                }
            }
        }
    }

    private func applyStep(_ direction: Int, editor: CPListTemplate, parent: CPListTemplate, index: Int, row: [String: Any]) {
        guard let state = parent.userInfo as? SettingsPageState, let view = state.snapshot["view"] as? String else { return }
        let attachedController = controller
        settingsRead?.cancel()
        settingsRead = nil
        busy = true
        for section in editor.sections {
            for case let item as CPListItem in section.items { item.isEnabled = false }
        }
        work?.cancel()
        work = Task {
            do {
                guard state.session == session else { throw BridgeError.message("Connection changed. Refresh settings.") }
                let pending = try await request("/api/settings/preview", payload: ["view": view, "row": index, "direction": direction])
                guard let intent = pending["intent"] as? String else { throw BridgeError.message("Refresh settings and try again.") }
                guard controller?.topTemplate === editor else {
                    busy = false
                    return
                }
                let result = try await request("/api/settings/confirm", payload: ["intent": intent, "confirmed": true])
                guard result["saved"] as? Bool == true else { throw BridgeError.message("Save could not be confirmed. Check the current value.") }
                let snapshot = try await settingsSnapshot(state)
                _ = state.update(snapshot, session: session)
                busy = false
                drawSettings(parent)
                guard controller?.topTemplate === editor else { return }
                guard let rows = state.snapshot["rows"] as? [[String: Any]], rows.indices.contains(index),
                      rows[index]["label"] as? String == row["label"] as? String,
                      ((rows[index]["step"] as? NSNumber)?.doubleValue ?? 0) > 0,
                      (rows[index]["choices"] as? [String] ?? []).isEmpty else {
                    popTemplate(animated: true, completion: nil)
                    return
                }
                if let editorState = editor.userInfo as? SettingsEditorState {
                    drawEditor(editor, state: editorState, row: rows[index])
                }
            } catch {
                guard !Task.isCancelled, controller === attachedController else { return }
                busy = false
                let message = error.localizedDescription
                if controller?.topTemplate === editor {
                    popTemplate(animated: true) { [weak self] _, _ in
                        self?.loadSettings(parent)
                        self?.notice(message)
                    }
                } else {
                    loadSettings(parent)
                }
            }
        }
    }
    private func preview(_ page: CPListTemplate, index: Int, selection: String? = nil, detailRow: [String: Any]? = nil) {
        guard !busy, let state = page.userInfo as? SettingsPageState, state.session == session,
              let view = state.snapshot["view"] as? String else { loadSettings(page); return }
        busy = true
        let original = session
        settingsRead?.cancel()
        settingsRead = nil
        Task { [weak self, weak page] in
            guard let self, let page else { return }
            defer { self.busy = false }
            do {
                var payload: [String: Any] = ["view": view, "row": index]
                if let selection {
                    payload["value"] = selection
                } else {
                    payload["direction"] = 0
                }
                let pending = try await self.request("/api/settings/preview", payload: payload)
                guard let intent = pending["intent"] as? String else { throw BridgeError.message("Refresh settings and try again.") }
                let confirm = CPAlertAction(title: localizedCarPlay("Save"), style: .default) { [weak self, weak page] _ in
                    guard let self, let page else { return }
                    self.controller?.dismissTemplate(animated: true) { _, _ in
                        guard original == self.session else { self.notice("Connection changed. Refresh settings."); return }
                        self.commit(intent, page: page)
                    }
                }
                let cancel = CPAlertAction(title: localizedCarPlay("Cancel"), style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
                let question = pending["question"] as? String ?? "Save this preference?"
                if let detailRow, let reason = detailRow["reason"] as? String, !reason.isEmpty {
                    let details = CPAlertAction(title: self.localizedCarPlay("Details"), style: .default) { [weak self] _ in
                        self?.controller?.dismissTemplate(animated: true) { success, _ in
                            if success { self?.showSettingDetails(detailRow) }
                        }
                    }
                    self.controller?.presentTemplate(CPActionSheetTemplate(title: question, message: self.localizedCarPlay(reason),
                        actions: [confirm, details, cancel]), animated: true, completion: nil)
                } else {
                    self.controller?.presentTemplate(CPAlertTemplate(titleVariants: [question], actions: [cancel, confirm]), animated: true, completion: nil)
                }
            } catch { self.notice(error.localizedDescription); self.busy = false; self.loadSettings(page) }
        }
    }
    private func commit(_ intent: String, page: CPListTemplate) {
        guard !busy else { return }
        busy = true
        Task { [weak self, weak page] in
            guard let self, let page else { return }
            do {
                let result = try await self.request("/api/settings/confirm", payload: ["intent": intent, "confirmed": true])
                if result["saved"] as? Bool != true { self.notice("Save could not be confirmed. Check the current value.") }
            } catch { self.notice(error.localizedDescription) }
            self.busy = false
            if let editor = self.visibleSettingsList?.userInfo as? SettingsEditorState, editor.parent === page {
                self.popTemplate(animated: true) { [weak self, weak page] _, _ in
                    if let page { self?.loadSettings(page) }
                }
            } else { self.loadSettings(page) }
        }
    }
    private func paging<T: CPTemplate & CPBarButtonProviding>(_ page: T, index: Int, count: Int, change: @escaping @MainActor (Int) -> Void) {
        var items: [CPBarButton] = []
        if index > 0 { items.append(CPBarButton(image: UIImage(systemName: "chevron.left")!) { _ in change(index - 1) }) }
        if index + 1 < count { items.append(CPBarButton(image: UIImage(systemName: "chevron.right")!) { _ in change(index + 1) }) }
        page.trailingNavigationBarButtons = items
    }

    private func notice(_ message: String) {
        guard controller?.presentedTemplate == nil else { return }
        let action = CPAlertAction(title: localizedCarPlay("OK"), style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
        controller?.presentTemplate(CPAlertTemplate(titleVariants: [String(message.prefix(240))], actions: [action]), animated: true, completion: nil)
    }
}

@MainActor
final class CarPlayDashboardSceneDelegate: NSObject, CPTemplateApplicationDashboardSceneDelegate {
    private var window: UIWindow?
    private var dashboardController: CPDashboardController?
    private var mapController: CompanionCarPlayMap?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                          didConnect dashboardController: CPDashboardController,
                                          to window: UIWindow) {
        self.window = window
        self.dashboardController = dashboardController
        dashboardController.shortcutButtons = []
        let model = AppModel.shared
        model.$navigationEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        timer?.invalidate(); timer = nil
    }

    private func refresh() {
        guard let window else { return }
        guard AppModel.shared.navigationEnabled else {
            if window.rootViewController == nil || mapController != nil {
                window.rootViewController = UIViewController()
            }
            mapController = nil
            return
        }
        if mapController == nil {
            let map = CompanionCarPlayMap()
            map.dashboard = true
            mapController = map
            window.rootViewController = map
        }
        mapController?.update(AppModel.shared.navigationServices.navigation)
    }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                          didDisconnect dashboardController: CPDashboardController,
                                          from window: UIWindow) {
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        window.rootViewController = nil
        mapController = nil; self.window = nil; self.dashboardController = nil
    }
}

@MainActor
private final class CompanionCarPlayMap: UIViewController, MKMapViewDelegate {
    private lazy var map = MKMapView()
    private let markerPerspective = DriveMarkerPerspective()
    private var mapboxHost: UIHostingController<MapboxDriveMap>?
    private var lastMapboxOptions: CarDisplayMapOptions?
    private var lastMapboxToken: String?
    private let position = MKPointAnnotation()
    private let destinationPin = MKPointAnnotation()
    private var showingDestination = false
    var dashboard = false
    var showingOverview = false { didSet { showingDestination = false } }
    private var zoomFactor = 1.0
    private var routePoints: [RoutePoint] = []
    private var line: MKPolyline?
    private var lastLocation: CLLocation?
    private var lastMovement = Date.distantPast
    private var filteredSpeed = 0.0
    private var cameraDistance = 900.0
    func zoom(by factor: Double) {
        zoomFactor = min(3, max(0.35, zoomFactor * factor))
    }

    private var visibleMapFrame: CGRect {
        let safe = map.safeAreaLayoutGuide.layoutFrame
        let fallback = safe.isEmpty ? map.bounds : safe
        guard let window = map.window as? CPWindow, !dashboard else { return fallback }
        let frame = map.convert(window.mapButtonSafeAreaLayoutGuide.layoutFrame, from: window).intersection(fallback)
        return frame.width >= 64 && frame.height >= 64 ? frame : fallback
    }

    private func follow(_ coordinate: CLLocationCoordinate2D, heading: Double, pitch: CGFloat, animated: Bool) {
        let frame = visibleMapFrame
        guard !frame.isEmpty else { return }
        let distance = cameraDistance * zoomFactor
        // Measure the ground offset in MapKit's pitched projection. Rotating this
        // offset into the new heading keeps the arrow anchored through turns.
        let camera = MKMapCamera(lookingAtCenter: coordinate, fromDistance: distance, pitch: pitch, heading: heading)
        if !animated {
            map.setCamera(camera, animated: false)
        }
        let current = map.camera
        let safe = map.safeAreaLayoutGuide.layoutFrame
        let x = CarDisplayMapOptions.followX(in: safe.isEmpty ? frame : safe, dashboard: dashboard,
                                             rightToLeft: map.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        let anchor = CGPoint(x: x,
                             y: frame.minY + max(frame.height * 0.45, frame.height - (dashboard ? 26 : min(60, frame.height * 0.23))))
        let ground = map.convert(anchor, toCoordinateFrom: map)
        if CLLocationCoordinate2DIsValid(ground), current.centerCoordinateDistance > 0 {
            let center = MKMapPoint(current.centerCoordinate)
            let foot = MKMapPoint(ground)
            let scale = distance / current.centerCoordinateDistance
            let angle = (heading - current.heading) * .pi / 180
            let dx = (center.x - foot.x) * scale
            let dy = (center.y - foot.y) * scale
            let car = MKMapPoint(coordinate)
            let aim = MKMapPoint(x: car.x + dx * cos(angle) - dy * sin(angle),
                                 y: car.y + dx * sin(angle) + dy * cos(angle))
            if car.distance(to: aim) < distance * 2, CLLocationCoordinate2DIsValid(aim.coordinate) {
                camera.centerCoordinate = aim.coordinate
            }
        }
        map.setCamera(camera, animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }
    override func loadView() {
        view = UIView()
    }

    private var appleStyle: GalaxyAppleMap?
    private func installAppleMap() {
        let style = UserDefaults.standard.string(forKey: "navigation.appleStyle").flatMap(GalaxyAppleMap.init(rawValue:)) ?? .streets
        if style != appleStyle {
            let config = style.configuration
            (config as? MKStandardMapConfiguration)?.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
            appleStyle = style
        }
        guard map.superview == nil else { return }
        map.frame = view.bounds
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(map)
        map.delegate = self
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = false
    }
    func update(_ navigation: NavigationModel) {
        loadViewIfNeeded()
        if let token = NavigationMapPreference.activeToken {
            let phoneScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.session.role == .windowApplication }
            let height = view.bounds.height
            let options = CarDisplayMapOptions(overview: showingOverview, zoomFactor: zoomFactor, dashboard: dashboard,
                phoneMapHeight: phoneScene?.coordinateSpace.bounds.height ?? height, mapHeight: height,
                maximumFPS: Float(max(1, min(60, view.window?.screen.maximumFramesPerSecond ?? 60))))
            if lastMapboxToken != token || lastMapboxOptions != options {
                let screen = MapboxDriveMap(navigation: navigation, token: token,
                                           markerPerspective: markerPerspective, tripFrame: .zero, carDisplay: options)
                if let host = mapboxHost {
                    host.rootView = screen
                } else {
                    let host = UIHostingController(rootView: screen)
                    addChild(host)
                    host.view.frame = view.bounds
                    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(host.view)
                    host.didMove(toParent: self)
                    mapboxHost = host
                    if map.isDescendant(of: view) { map.removeFromSuperview() }
                }
                lastMapboxOptions = options
                lastMapboxToken = token
            }
            return
        }
        if let host = mapboxHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            mapboxHost = nil
            lastMapboxToken = nil
        }
        installAppleMap()
        if let destination = navigation.destination {
            let coordinate = destination.coordinate
            if destinationPin.coordinate.latitude != coordinate.latitude || destinationPin.coordinate.longitude != coordinate.longitude {
                showingDestination = false
                destinationPin.coordinate = coordinate
            }
            destinationPin.title = destination.name
            if !map.annotations.contains(where: { $0 === destinationPin }) { map.addAnnotation(destinationPin) }
        } else {
            map.removeAnnotation(destinationPin)
            showingDestination = false
        }
        let next = navigation.usingComma ? navigation.commaPolyline : navigation.route?.polyline
        if line !== next {
            map.removeOverlays(map.overlays)
            showingDestination = false
            line = next
            routePoints = next.map { line in
                let points = line.points()
                return (0..<line.pointCount).map { index in
                    let coordinate = points[index].coordinate
                    return RoutePoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
            } ?? []
            if let next { map.addOverlays([MKMultiPolyline([next]), next], level: .aboveRoads) }
        }
        let coordinate = navigation.usingComma ? (navigation.commaFeedReady ? navigation.commaPosition : nil) : navigation.goodLocation?.coordinate
        if let coordinate {
            let now = Date()
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let previous = lastLocation {
                let meters = previous.distance(from: location)
                let elapsed = now.timeIntervalSince(lastMovement)
                if meters >= 1, elapsed > 0 {
                    let speed = meters / elapsed
                    if elapsed < 5, speed <= 55 {
                        filteredSpeed += (speed - filteredSpeed) * (1 - exp(-elapsed / 3))
                    }
                    lastLocation = location; lastMovement = now
                } else if elapsed > 3 { filteredSpeed *= 0.8 }
            } else { lastLocation = location; lastMovement = now }
            let target = 0.50 * NavigationMapMotion.cameraDistance(speed: filteredSpeed,
                distanceToTurn: navigation.navigating ? navigation.distanceToTurn : 0)
            cameraDistance += (target - cameraDistance) * (target < cameraDistance ? 0.35 : 0.2)
            let displayed = navigation.navigating ? NavigationMapMotion.alignedCoordinate(coordinate, route: routePoints) : coordinate
            let hadPosition = map.annotations.contains(where: { $0 === position })
            if hadPosition && !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.8, delay: 0, options: [.beginFromCurrentState, .curveLinear]) {
                    self.position.coordinate = displayed
                }
            } else { position.coordinate = displayed }
            if !hadPosition { map.addAnnotation(position) }
            let course = navigation.usingComma ? navigation.commaHeading : navigation.goodLocation?.course ?? -1
            let heading = course.isFinite && course >= 0 ? course : map.camera.heading
            if !showingOverview || next == nil {
                showingDestination = false
                let pitch = navigation.followPitch(cruising: dashboard ? 55 : 66, speed: filteredSpeed)
                follow(displayed, heading: heading, pitch: CGFloat(pitch), animated: hadPosition)
            }
            if let marker = map.view(for: position), showingOverview {
                marker.transform = CGAffineTransform(rotationAngle: (heading - map.camera.heading) * .pi / 180)
            } else { map.view(for: position)?.transform = .identity }
        } else {
            map.removeAnnotation(position)
            lastLocation = nil; filteredSpeed = 0
        }
        if coordinate == nil || showingOverview {
            if !showingDestination, let destination = navigation.destination, !map.bounds.isEmpty {
                if let next {
                    let frame = visibleMapFrame
                    let margin = min(20, min(frame.width, frame.height) / 8)
                    map.setVisibleMapRect(next.boundingMapRect, edgePadding: UIEdgeInsets(
                        top: frame.minY + margin, left: frame.minX + margin,
                        bottom: map.bounds.maxY - frame.maxY + margin, right: map.bounds.maxX - frame.maxX + margin), animated: false)
                } else {
                    map.setRegion(MKCoordinateRegion(center: destination.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500), animated: false)
                }
                showingDestination = true
            }
        }
    }
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let casing = overlay as? MKMultiPolyline {
            let renderer = MKMultiPolylineRenderer(multiPolyline: casing)
            renderer.strokeColor = UIColor(red: 0.30, green: 0.18, blue: 0.48, alpha: 1)
            renderer.lineCap = .round; renderer.lineJoin = .round; renderer.lineWidth = 8
            return renderer
        }
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = StarPilotTheme.routePurple
        renderer.lineCap = .round; renderer.lineJoin = .round
        renderer.lineWidth = 6
        return renderer
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === destinationPin {
            let pin = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
            pin.markerTintColor = StarPilotTheme.uiAccent
            pin.glyphImage = UIImage(systemName: "flag.checkered")
            return pin
        }
        let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        marker.image = UIGraphicsImageRenderer(size: CGSize(width: 25, height: 21)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 25, height: 21))
            StarPilotTheme.uiAccent.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 1.5, y: 1.5, width: 22, height: 18))
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 12.5, y: 3)); arrow.addLine(to: CGPoint(x: 19, y: 16))
            arrow.addLine(to: CGPoint(x: 12.5, y: 13)); arrow.addLine(to: CGPoint(x: 6, y: 16))
            arrow.close(); UIColor.white.setFill(); arrow.fill()
        }
        marker.displayPriority = .required
        return marker
    }
}
