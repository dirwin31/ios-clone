import CarPlay
import UIKit
import SwiftUI
import CoreFoundation
import CoreText
import MapKit
import Combine

@MainActor
final class CarPlayDashboardSceneDelegate: NSObject, @preconcurrency CPTemplateApplicationDashboardSceneDelegate {
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
final class CompanionCarPlayMap: UIViewController, MKMapViewDelegate {
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
        let anchor = CGPoint(x: x, y: CarDisplayMapOptions.followY(height: map.bounds.height,
            bottomInset: map.safeAreaInsets.bottom, dashboard: dashboard))
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
        let fix = navigation.carPlayLocation(at: .now)
        let coordinate = fix?.coordinate
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
            let course = fix?.course ?? -1
            let phone = navigation.goodLocation
            let hasSpeed = phone.map { (0...2).contains(-$0.timestamp.timeIntervalSinceNow) && $0.speed >= 0 && $0.distance(from: location) <= 30 } ?? false
            let canRotate = !hadPosition || (hasSpeed ? (phone?.speed ?? 0) >= 2.5 : filteredSpeed >= 2.5 && now.timeIntervalSince(lastMovement) < 1)
            let heading = canRotate && course.isFinite && course >= 0 ? course : map.camera.heading
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
