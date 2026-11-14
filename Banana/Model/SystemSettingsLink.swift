#if os(macOS) || os(iOS)
import Foundation
#if os(iOS)
import UIKit
#endif

/// Where a permission can be changed after the system can no longer ask for it.
enum SystemSettingsLink: Hashable, Sendable {
    case app, notifications, location, reminders, music, photos

    var url: URL {
        #if os(macOS)
        if self == .notifications {
            var parts = URLComponents(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            parts.queryItems = [URLQueryItem(name: "id", value: Bundle.main.bundleIdentifier)]
            return parts.url!
        }
        let anchor: String? = switch self {
        case .app: nil
        case .location: "Privacy_LocationServices"
        case .reminders: "Privacy_Reminders"
        case .music: "Privacy_Media"
        case .photos: "Privacy_Photos"
        case .notifications: nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security" + (anchor.map { "?" + $0 } ?? ""))!
        #else
        return URL(string: UIApplication.openSettingsURLString)!
        #endif
    }
}
#endif
