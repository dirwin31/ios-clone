import SwiftUI
import MapKit

/// Places shared from Google or Apple Maps through starpilot://share. Native navigation opens a shared place directly;
/// otherwise Galaxy's navigation page receives the text, the same way Android's share target hands it over.
@MainActor
final class ShareInbox: ObservableObject {
    static let shared = ShareInbox()
    /// Text waiting for the Galaxy page to load it.
    @Published var galaxyText: String?
    /// The Galaxy page is being sent the text; it is cleared once that succeeds.
    var sending = false
    private let probe = RedirectProbe()

    func receive(_ url: URL, model: AppModel) {
        guard let text = SharedDestination.text(from: url) else { return }
        model.connectionLog.record("Shared destination received")
        Task {
            // Short links are opened on the phone so any comma's Galaxy can read the coordinates.
            let resolved = await SharedDestination.resolve(text) { [probe] in await probe.location(of: $0) }
            open(resolved, model: model)
        }
    }

    private func open(_ text: String, model: AppModel) {
        if model.navigationEnabled, case let .place(name, latitude, longitude) = SharedDestination.parse(text) {
            let navigation = model.navigationServices.navigation
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
            item.name = name
            model.tab = .navigation
            if navigation.navigating || navigation.busy {
                navigation.notice = "End the current route to open the shared place."
                return
            }
            Task { await navigation.select(NavigationPlace(item: item, subtitle: "Shared from Maps")) }
            return
        }
        galaxyText = text
        model.tab = model.opened ? .galaxy : .connections
    }

    /// Galaxy reloads into its navigation page with the shared text, which it opens or searches.
    func script() -> String? {
        guard !sending, let text = galaxyText, let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return nil }
        return "location.assign(location.pathname + '?share=' + encodeURIComponent(\(literal)) + '#/navigation')"
    }
}
