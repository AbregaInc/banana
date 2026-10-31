import Foundation

/// Whether this install runs the data platform (docs/design/DATA-PLATFORM.md): the engine, the
/// adapters and the move off iCloud. On in every build, Stable and Beta; off only when launched
/// with `--no-space-sync` (tests, and today's iCloud-only behaviour on purpose).
enum SpaceSyncFlag {
    static let offArgument = "--no-space-sync"

    /// For tests: the flag as set here, whatever the launch arguments say. Nil: they decide.
    static var override: Bool?

    static var isOn: Bool { override ?? !ProcessInfo.processInfo.arguments.contains(offArgument) }
}
