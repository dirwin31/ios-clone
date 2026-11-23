import SwiftUI
import CoreLocation
import MapboxNavigationCore
import MapboxNavigationUIKit
import MapboxMaps

@MainActor
enum GalaxyNavigationSDK {
    private static var saved: MapboxNavigationProvider?

    static func provider(token: String) -> MapboxNavigationProvider {
        let prefs = UserDefaults.standard
        let source = prefs.string(forKey: "navigation.sdkSource")
        var routing = RoutingConfig()
        routing.routingProviderSource = source == "Offline" ? .offline : source == "Online" ? .online : .hybrid
        routing.rerouteConfig.detectsReroute = prefs.object(forKey: "navigation.sdkReroute") as? Bool ?? true
        if prefs.object(forKey: "navigation.sdkFasterRoutes") as? Bool == false { routing.fasterRouteDetectionConfig = nil }
        if prefs.object(forKey: "navigation.offerAlternatives") as? Bool == false { routing.alternativeRoutesDetectionConfig = nil }
        let units = prefs.string(forKey: NavigationDistanceUnits.key)
        let config = CoreConfig(credentials: .init(accessToken: token), routingConfig: routing,
                                unitOfMeasurement: units == "metric" ? .metric : units == "imperial" ? .imperial : .auto,
                                ttsConfig: prefs.bool(forKey: "navigation.sdkLocalVoice") ? .localOnly : .default)
        if let saved {
            if saved.coreConfig != config { saved.apply(coreConfig: config) }
            return saved
        }
        let provider = MapboxNavigationProvider(coreConfig: config)
        saved = provider
        return provider
    }
}

struct MapboxNavigatorScreen: View {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var routes: NavigationRoutes?
    @State private var errorMessage = ""

    var body: some View {
        Group {
            if let routes {
                NavigatorController(routes: routes, provider: GalaxyNavigationSDK.provider(token: token)) { dismiss() }
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    if errorMessage.isEmpty { ProgressView("Finding a driving route…") }
                    else { Text(errorMessage).multilineTextAlignment(.center) }
                    Button("Close") { dismiss() }
                }.padding()
            }
        }.task {
            let options = NavigationRouteOptions(coordinates: [origin, destination])
            let prefs = UserDefaults.standard
            options.includesAlternativeRoutes = prefs.object(forKey: "navigation.offerAlternatives") as? Bool ?? true
            if prefs.bool(forKey: "navigation.avoidTolls") { options.roadClassesToAvoid.insert(.toll) }
            if prefs.bool(forKey: "navigation.avoidMotorways") { options.roadClassesToAvoid.insert(.motorway) }
            if prefs.bool(forKey: "navigation.avoidFerries") { options.roadClassesToAvoid.insert(.ferry) }
            if prefs.bool(forKey: "navigation.avoidUnpaved") { options.roadClassesToAvoid.insert(.unpaved) }
            if prefs.bool(forKey: "navigation.avoidCashTolls") { options.roadClassesToAvoid.insert(.cashTollOnly) }
            if prefs.bool(forKey: "navigation.vehicleLimits") {
                options.maximumHeight = .init(value: prefs.object(forKey: "navigation.max_height") as? Double ?? 1.6, unit: .meters)
                options.maximumWidth = .init(value: prefs.object(forKey: "navigation.max_width") as? Double ?? 1.9, unit: .meters)
                options.maximumWeight = .init(value: prefs.object(forKey: "navigation.max_weight") as? Double ?? 2.5, unit: .metricTons)
            }
            let request = GalaxyNavigationSDK.provider(token: token).mapboxNavigation.routingProvider().calculateRoutes(options: options)
            do {
                let result = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
                if !Task.isCancelled { routes = result }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct NavigatorController: UIViewControllerRepresentable {
    let routes: NavigationRoutes
    let provider: MapboxNavigationProvider
    let close: () -> Void
    final class Coordinator: NSObject, NavigationViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func navigationViewControllerDidDismiss(_ controller: NavigationViewController, byCanceling canceled: Bool) {
            close()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(close: close) }
    func makeUIViewController(context: Context) -> NavigationViewController {
        let options = NavigationOptions(mapboxNavigation: provider.mapboxNavigation,
                                        voiceController: provider.routeVoiceController, eventsManager: provider.eventsManager())
        let controller = NavigationViewController(navigationRoutes: routes, navigationOptions: options)
        controller.delegate = context.coordinator
        controller.loadViewIfNeeded()
        let prefs = UserDefaults.standard
        controller.showsSpeedLimits = prefs.object(forKey: "navigation.sdkSpeedLimits") as? Bool ?? true
        controller.annotatesIntersectionsAlongRoute = prefs.object(forKey: "navigation.sdkIntersections") as? Bool ?? true
        controller.usesNightStyleWhileInTunnel = prefs.object(forKey: "navigation.sdkDarkTunnels") as? Bool ?? true
        controller.routeLineTracksTraversal = prefs.object(forKey: "navigation.sdkFadeRoute") as? Bool ?? true
        controller.showsContinuousAlternatives = prefs.object(forKey: "navigation.offerAlternatives") as? Bool ?? true
        return controller
    }
    func updateUIViewController(_ controller: NavigationViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: NavigationViewController, coordinator: Coordinator) {
        controller.mapboxNavigation.tripSession().setToIdle()
    }
}
