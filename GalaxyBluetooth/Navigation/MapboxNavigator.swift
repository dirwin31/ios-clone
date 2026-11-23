import SwiftUI
import CoreLocation
import MapboxNavigationCore
import MapboxNavigationUIKit
import MapboxMaps

@MainActor
enum GalaxyNavigationSDK {
    private static var saved: (String, MapboxNavigationProvider)?

    static func provider(token: String) -> MapboxNavigationProvider {
        if let saved, saved.0 == token { return saved.1 }
        saved = nil
        MapboxOptions.accessToken = token
        let provider = MapboxNavigationProvider(coreConfig: .init(credentials: .init(accessToken: token)))
        saved = (token, provider)
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
