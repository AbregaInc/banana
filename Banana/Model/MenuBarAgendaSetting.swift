import Foundation

/// Where "Next meeting in the menu bar" is kept, and the one-time move from the key it used to
/// have.
///
/// That key had a dot in it (`menuBarAgenda.enabled`). `@AppStorage` observes its key through
/// key-value observing, which reads a dot as a key path, and a dotted key re-rendered the screen
/// that held it continuously — the 26 Sep render storm (`ShellNavigation.defaultsKey` and the trip
/// time zone keys were renamed for the same reason). The Mac Settings screen still had the one.
/// The key is dot-free now, and a switch someone had turned off stays off.
enum MenuBarAgendaSetting {
    static let key = "menuBarAgendaEnabled"
    static let legacyKey = "menuBarAgenda.enabled"

    /// Carries what the old key held to the new one, once: only when the new key has never been
    /// set and the old one has. Once the new key exists it is what the person last chose and the
    /// old value is stale, so it is never copied over it. With neither set nothing is written, so
    /// every reader falls back to its own default (on). The old key is left where it is — an older
    /// build still finds its setting — and nothing reads it any more.
    static func migrateLegacyKey(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil,
              let old = defaults.object(forKey: legacyKey) as? Bool else { return }
        defaults.set(old, forKey: key)
    }
}
