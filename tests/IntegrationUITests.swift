import XCTest
import UIKit

final class IntegrationUITests: XCTestCase {
    func testLandingAndGalaxyPillLayouts() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 15))
        capture("Landing portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        // XCTest can report the new orientation while UIKit is still animating rotation.
        Thread.sleep(forTimeInterval: 0.8)
        let heading = app.staticTexts["Your comma"]
        XCTAssertFalse(heading.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(heading.frame))
        capture("Landing landscape")
        app.terminate()
        launchGalaxyFixture(app)
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 0.8)
            let controls = ["back","home","toggles","tools","routes","options"].map { app.buttons["galaxy-pill-" + $0] }
            XCTAssertTrue(controls[0].waitForExistence(timeout: 30), app.debugDescription)
            for (index, control) in controls.enumerated() {
                XCTAssertTrue(control.isHittable, control.debugDescription)
                XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(control.frame), control.debugDescription)
                for earlier in controls.prefix(index) {
                    XCTAssertFalse(earlier.frame.insetBy(dx: 3, dy: 3).intersects(control.frame.insetBy(dx: 3, dy: 3)),
                                   "Toolbar buttons overlap: \(earlier.identifier) and \(control.identifier)")
                }
            }
            controls[3].tap()
            XCTAssertTrue(app.webViews.staticTexts["Tools selected"].waitForExistence(timeout: 8))
            controls[1].tap()
            XCTAssertTrue(app.webViews.staticTexts["Home selected"].waitForExistence(timeout: 8))
            capture(orientation == .portrait ? "Galaxy pill portrait" : "Galaxy pill landscape")
            if app.buttons["galaxy-app-tabs"].exists {
                app.buttons["galaxy-app-tabs"].tap()
            } else {
                app.buttons["galaxy-pill-options"].tap()
                app.buttons["Show app tabs"].tap()
            }
            XCTAssertTrue(app.buttons["main-tab-Settings"].waitForExistence(timeout: 5))
            app.buttons["main-tab-Galaxy"].tap()
            XCTAssertTrue(app.buttons["galaxy-pill-options"].waitForExistence(timeout: 5))
        }
        app.buttons["galaxy-pill-options"].tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 8))
    }
    private func launchGalaxyFixture(_ app: XCUIApplication, motionEnabled: Bool = true) {
        app.launchArguments = ["--preview-galaxy", "-galaxy.galacticalAnimations", motionEnabled ? "YES" : "NO"]
        app.launchEnvironment["GALAXY_UI_FIXTURE"] = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:18px system-ui;margin:0}header,nav{height:55px}main{padding:12px}h1{margin-top:0}</style>
        <div id="galaxy-app"><div class="gx-app"><header class="gx-appbar">
        <button class="gx-appbar__back">Back</button><button class="gx-appbar__home">Galaxy</button>
        <button class="gx-theme-toggle">Theme</button><button class="gx-appbar__menu">Menu</button></header>
        <main class="gx-content"><h1>Galaxy layout preview</h1><p id="selection">Home selected</p></main>
        <nav class="blur-nav"><button aria-current="page"><i class="bi-house-fill"></i>Home</button>
        <button><i class="bi-toggle-on"></i>Toggles</button><button><i class="bi-tools"></i>Tools</button>
        <button><i class="bi-camera-reels"></i>Routes</button></nav></div></div>
        <script>document.querySelector('nav').onclick=e=>{const b=e.target.closest('button');if(b){
        document.querySelector('[aria-current]')?.removeAttribute('aria-current');b.setAttribute('aria-current','page');
        document.getElementById('selection').textContent=b.textContent+' selected';}};</script>
        """
        app.launch()
    }

    func testGalaxyPillMotion() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        launchGalaxyFixture(app)
        let tools = app.buttons["galaxy-pill-tools"]
        let home = app.buttons["galaxy-pill-home"]
        XCTAssertTrue(tools.waitForExistence(timeout: 30))
        if #available(iOS 26.0, *) {
            let options = XCTMeasureOptions()
            options.iterationCount = 3
            measure(metrics: [XCTHitchMetric(application: app)], options: options) {
                tools.tap()
                home.tap()
            }
        }
        XCTAssertTrue(app.webViews.staticTexts["Home selected"].waitForExistence(timeout: 8))
        app.terminate()
        launchGalaxyFixture(app, motionEnabled: false)
        XCTAssertTrue(tools.waitForExistence(timeout: 30))
        tools.tap()
        XCTAssertTrue(app.webViews.staticTexts["Tools selected"].waitForExistence(timeout: 8))
        let selection = NSPredicate(format: "selected == true OR value == %@", "Selected")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selection, object: tools)], timeout: 5), .completed)
    }

    private func openSettingsSection(_ title: String, containing control: XCUIElement, in app: XCUIApplication) {
        guard !control.exists else { return }
        let header = app.buttons[title]
        for _ in 0..<4 where !header.isHittable { app.swipeUp() }
        header.tap()
        XCTAssertTrue(control.waitForExistence(timeout: 5))
    }
    func testTunnelSetupValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "NO", "-galaxy.app.navigationEnabled", "NO"]
        app.launch()
        let setup = app.buttons["tunnel-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15))
        if !setup.isHittable { app.swipeUp() }
        setup.tap()
        XCTAssertTrue(app.navigationBars["Galaxy tunnel"].waitForExistence(timeout: 5))
        let address = app.textFields.firstMatch
        address.tap(); address.typeText("not-a-link")
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["Paste your full Galaxy link, including its 16-character code."].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
    }
    func testConnectionOrderSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "NO", "-galaxy.app.navigationEnabled", "NO", "-galaxy.connection.mode", "automatic"]
        app.launch()
        XCTAssertTrue(app.buttons["Set order"].waitForExistence(timeout: 15))
        app.buttons["Set order"].tap()
        XCTAssertTrue(app.navigationBars["Connection order"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tunnel"].exists)
        app.buttons["Reset order"].tap()
        let drag = app.buttons["Reorder Tunnel"]
        XCTAssertTrue(drag.exists)
        drag.press(forDuration: 0.7, thenDragTo: app.buttons["Reorder Local Wi-Fi"])
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Tunnel → Local Wi-Fi → Bluetooth"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Tunnel → Local Wi-Fi → Bluetooth"].waitForExistence(timeout: 10))
        app.buttons["Set order"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Connection priority"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Reset order"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Local Wi-Fi → Tunnel → Bluetooth"].exists)
    }
    func testDiagnosticsExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "YES", "-galaxy.app.navigationEnabled", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Developer options"].waitForExistence(timeout: 10))
        app.buttons["Developer options"].tap()
        app.buttons["Dev / Logs"].tap()
        let save = app.buttons["save-diagnostics-zip"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Share diagnostics text file"; shot.lifetime = .keepAlways; add(shot)
    }
    func testPhoneNavigationPlannerAndDrive() {
        let isDuo = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        let device = isDuo ? "Duo" : "iPhone"
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.launchArguments = ["--preview-navigation-planner", "--ui-testing", "-navigation.usePhoneOnlyDirections", "YES", "-navigation.phoneRouter", "Apple Maps",
                               "-navigation.mapboxSetupSeen", "NO", "-navigation.mapboxEnabled", "YES"]
        app.launch()
        let useAppleMaps = app.buttons["Use Apple Maps for the map display"]
        XCTAssertTrue(useAppleMaps.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Recommended for 3D navigation"].exists)
        XCTAssertTrue(app.staticTexts["2. On the comma, open Bluetooth settings and tap Share Mapbox key."].exists)
        useAppleMaps.tap()
        let field = app.textFields["map-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["home-shortcut"].isHittable)
        XCTAssertTrue(app.staticTexts["Recent"].exists)
        let handle = app.buttons["place-panel-handle"]
        handle.tap()
        XCTAssertTrue(app.buttons["Saved places & recents"].isHittable)
        handle.tap()
        XCTAssertTrue(app.buttons["home-shortcut"].isHittable)
        if !isDuo { XCTAssertTrue(app.buttons["expand-app-tabs"].isHittable) }
        capture("\(device) destination planner")
        app.buttons["Navigation options"].tap()
        app.buttons["Navigation settings"].tap()
        XCTAssertTrue(app.navigationBars["Navigation settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["navigation-map-appearance"].exists)
        app.buttons["navigation-distance-units"].tap()
        app.buttons["Metric"].tap()
        app.buttons["Done"].tap()
        field.tap()
        field.typeText("Test")
        let result = app.buttons["place-search-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        capture("\(device) inline search")
        result.tap()
        let directions = app.buttons["Start Route"]
        XCTAssertTrue(directions.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apple Maps · iPhone and CarPlay only"].exists)
        XCTAssertTrue(directions.isEnabled, "An iPhone-only trip can start without a paired comma")
        XCTAssertTrue(app.frame.contains(directions.frame))
        XCTAssertFalse(app.buttons["directions-source"].exists)
        capture("\(device) route preview")
        XCTAssertFalse(app.buttons["Save place options"].exists)
        app.buttons["Navigation options"].tap()
        XCTAssertTrue(app.buttons["Save as Home"].exists)
        app.buttons["Save as Work"].tap()
        XCTAssertTrue(app.buttons["phone-route-0"].label.contains("km"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.frame.contains(directions.frame))
        XCTAssertTrue(app.buttons["Close destination"].isHittable)
        let alternate = app.buttons["phone-route-1"]
        for _ in 0..<3 where !alternate.isHittable { app.scrollViews["route-itinerary"].swipeUp() }
        XCTAssertTrue(alternate.isHittable)
        alternate.tap()
        XCTAssertTrue(alternate.isSelected)
        capture("\(device) landscape planner")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--preview-route"]
        app.launch()
        XCTAssertTrue(app.buttons["End route"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Navigation options"].isHittable)
        if !isDuo { XCTAssertTrue(app.buttons["expand-app-tabs"].isHittable) }
        let mapViewButton = app.buttons["navigation-map-view"]
        XCTAssertEqual(mapViewButton.label, "Show full route")
        mapViewButton.tap()
        XCTAssertEqual(mapViewButton.label, "Resume following my location")
        mapViewButton.tap()
        XCTAssertEqual(mapViewButton.label, "Show full route")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 85, dy: 0)))
        let unlocked = NSPredicate(format: "label == %@", "Resume following my location")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unlocked, object: mapViewButton)], timeout: 4), .completed)
        mapViewButton.tap()
        XCTAssertEqual(mapViewButton.label, "Show full route")
        capture("\(device) active guidance")
        app.buttons["Navigation options"].tap()
        app.buttons["Navigation settings"].tap()
        XCTAssertTrue(app.navigationBars["Navigation settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["End route"].isHittable)
    }

    func testEdgeSwipesBetweenPages() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--preview-navigation-planner", "-navigation.mapboxSetupSeen", "YES"]
        app.launch()
        let search = app.textFields["map-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.55))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.55))
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -150, dy: 0)))
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 8))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 150, dy: 0)))
        XCTAssertTrue(search.waitForExistence(timeout: 8))
    }

    func testActiveRoutePreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-route"]; app.launch()
        XCTAssertTrue(app.staticTexts["Turn right onto Bremner Boulevard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["expand-app-tabs"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Sample active route"; shot.lifetime = .keepAlways; add(shot)
    }
    func testSelectedDestinationWithoutPhoneRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-galaxy.app.developerMode", "YES", "-galaxy.app.navigationEnabled", "YES",
                               "-navigation.offerPhoneTrip", "YES", "-navigation.defaultComma", "NO"]
        app.launch()
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        let tab = app.buttons["main-tab-Navigation"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let appleDisplay = app.buttons["Use Apple Maps for the map display"]
        if appleDisplay.waitForExistence(timeout: 3) { appleDisplay.tap() }
        let search = app.textFields["map-search"]
        search.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Test")
        let place = app.buttons["place-search-result"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 8))
        place.tap()
        let send = app.buttons["Send when connected"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let handle = app.buttons["place-panel-handle"]
        let before = handle.frame.midY
        let grab = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: 90)))
        XCTAssertTrue(app.buttons["Close destination"].isHittable)
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            handle.label == "Expand place panel" && handle.frame.midY > before + 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 3), .completed)
        XCTAssertGreaterThan(handle.frame.midY, before + 40)
        handle.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Get directions"].exists)
        XCTAssertFalse(app.buttons["directions-source"].exists)
        app.buttons["Navigation options"].tap()
        app.buttons["Navigation settings"].tap()
        let phoneOnly = app.switches["navigation-phone-only"]
        XCTAssertTrue(phoneOnly.waitForExistence(timeout: 5))
        XCTAssertEqual(phoneOnly.value as? String, "0")
        phoneOnly.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Get directions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start Route"].exists)
    }
    func testNavigationSettingsWithoutDeveloperMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "NO", "-galaxy.app.navigationEnabled", "YES"]
        app.launch()
        let settings = app.buttons["navigation-map-settings"]
        openSettingsSection("Navigation", containing: settings, in: app)
        XCTAssertTrue(app.buttons["settings-open-navigation"].exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Navigation settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Enable navigation"].exists)
    }
    func testNavigationAndSharedSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "YES", "-galaxy.app.navigationEnabled", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["main-tab-Navigation"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["bluetooth-connection-status"])], timeout: 10) == .completed)
        Thread.sleep(forTimeInterval: 0.7) // Capture the settled compact header, not its transition.
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Integrated navigation"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Navigation options"].tap()
        app.buttons["Reset navigation"].tap()
        XCTAssertTrue(app.staticTexts["Phone navigation cleared. Comma is not verified; its route was left unchanged."].waitForExistence(timeout: 5))
        app.buttons["Navigation options"].tap()
        app.buttons["Copy diagnostic report"].tap()
        XCTAssertTrue(app.staticTexts["Diagnostic report copied."].waitForExistence(timeout: 5))
        app.buttons["bluetooth-connection-status"].tap()
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 5))
        openSettingsSection("Phone & alerts", containing: app.staticTexts["Share phone location"], in: app)
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].exists)
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Settings"].tap()
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Shared settings"; settings.lifetime = .keepAlways; add(settings)
    }
}
