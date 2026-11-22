import SwiftUI
import UIKit

enum StarPilotTheme {
    // Shared by the native toolbar and the edge of the embedded Galaxy page.
    static func toolbarColor(dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.026, green: 0.022, blue: 0.058, alpha: 1)
             : UIColor(red: 0.895, green: 0.855, blue: 0.945, alpha: 1)
    }
    static let uiAccent = UIColor(red: 139.0 / 255, green: 108.0 / 255, blue: 197.0 / 255, alpha: 1)
    static let uiGuidance = UIColor(red: 117.0 / 255, green: 88.0 / 255, blue: 176.0 / 255, alpha: 1)
    static let accent = Color(uiColor: uiAccent)
    static let guidance = Color(uiColor: uiGuidance)
    static let background = Color(red: 0.035, green: 0.035, blue: 0.078)
    static let panel = Color(red: 0.09, green: 0.065, blue: 0.145)
    static let muted = Color(red: 0.70, green: 0.65, blue: 0.77)
    static func title(_ size: CGFloat) -> Font { .custom("Sora-Regular", size: size, relativeTo: .title2) }
}
