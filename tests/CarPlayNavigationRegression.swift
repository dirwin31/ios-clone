import Foundation
import CoreText

@MainActor final class UIImage {
    init?(systemName: String) {}
}
@MainActor final class CPBarButton {
    let action: (CPBarButton) -> Void
    init(image: UIImage, handler: @escaping (CPBarButton) -> Void) { action = handler }
}
@MainActor protocol CPBarButtonProviding: AnyObject {
    var backButton: CPBarButton? { get set }
}
@MainActor class CPTemplate: NSObject {}
@MainActor final class Page: CPTemplate, CPBarButtonProviding {
    var backButton: CPBarButton?
}
@MainActor final class CPInterfaceController {
    var templates: [CPTemplate] = [Page()]
    var topTemplate: CPTemplate? { templates.last }
    var pending: (() -> Void)?
    var deferNextPush = false
    func pushTemplate(_ page: CPTemplate, animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        precondition(templates.count < 4, "Exceeded physical depth")
        templates.append(page)
        if deferNextPush { deferNextPush = false; pending = { completion?(true, nil) } }
        else { completion?(true, nil) }
    }
    func popTemplate(animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        guard templates.count > 1 else { completion?(false, nil); return }
        templates.removeLast(); completion?(true, nil)
    }
}
@MainActor final class NavigationProbe {
    var controller: CPInterfaceController?
    var navigating = false
    let overflowParents = NSMapTable<CPTemplate, CPTemplate>.weakToStrongObjects()
    var notices: [String] = []
    func notice(_ message: String) { notices.append(message) }
    func localizedCarPlay(_ text: String) -> String { text }
    init(_ controller: CPInterfaceController) { self.controller = controller }
__PRODUCTION_METHODS__
}
@main struct NavigationRegression {
    @MainActor static func main() {
        let controller = CPInterfaceController(), probe = NavigationProbe(controller)
        let description = "Adjusts following distance. 🚘 " + String(repeating: "LongSettingName", count: 8) + "\nSaved on your comma."
        let lines = probe.descriptionLines(NSAttributedString(string: description), width: 120)
        precondition(lines.count > 2)
        precondition(lines.joined().filter { !$0.isWhitespace } == description.filter { !$0.isWhitespace })
        precondition(probe.descriptionLines(NSAttributedString(string: ""), width: 120).isEmpty)
        let settings = NavigationProbe.SettingsPageState("lane")
        func update(_ number: Int, _ toggle: String, _ token: String) -> Bool {
            settings.update(["view": token, "rows": [["value": number], ["value": toggle]]], session: "comma")
        }
        precondition(update(100, "Off", "a"))
        precondition(!update(100, "Off", "b"))
        precondition(settings.snapshot["view"] as? String == "b")
        precondition(update(101, "Off", "c"))
        precondition(update(101, "On", "d"))
        precondition(probe.displayedSettingValue(["value": 25, "unit": "%"]) == "25%")
        precondition(probe.displayedSettingValue(["value": 100, "displayScale": "lane-strength",
                                                 "minimum": 50, "maximum": 200]) == "5")
        let pages = (0..<12).map { _ in Page() }
        for page in pages {
            probe.pushTemplate(page, animated: true, completion: nil)
            precondition(controller.topTemplate === page)
            precondition(controller.templates.count <= 4)
        }
        for previous in pages.dropLast().reversed() {
            probe.popTemplate(animated: true, completion: nil)
            precondition(controller.topTemplate === previous, "Lost parent while returning")
        }
        probe.popTemplate(animated: true, completion: nil)
        precondition(controller.templates.count == 1)
        controller.deferNextPush = true
        probe.pushTemplate(Page(), animated: true, completion: nil)
        let count = controller.templates.count
        var accepted = true
        probe.pushTemplate(Page(), animated: true) { success, _ in accepted = success }
        precondition(!accepted && count == controller.templates.count, "Rapid tap pushed twice")
        controller.pending?(); controller.pending = nil
        precondition(!probe.navigating)
        print("CarPlay navigation: deep menus, Back restoration and rapid taps passed")
    }
}
