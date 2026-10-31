import Foundation

/// What this device is for — not how its screen is laid out (that's `LayoutClass`).
///
/// The iPhone is the hub for what only it can do: it reads Apple Health and publishes it, writes
/// workouts to Health, talks to the Watch, and rings alarms. Calendar busy blocks are not one of
/// them: every device writes those and they reconcile by ownership. `#if os(iOS)` used to stand in for "the phone"; with an iPad
/// build that would make the iPad a second hub, publishing the same records and writing the same
/// holds. Ask `DeviceRole.current.isHub` instead.
enum DeviceRole: Sendable {
    case phone
    case pad
    case mac

    /// From the hardware model ("iPad16,3"; the Simulator names the device it plays in an
    /// environment variable), which any thread may read — sync and background code ask too, and
    /// `UIDevice` belongs to the main thread.
    static let current: DeviceRole = {
        #if os(macOS)
        return .mac
        #else
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return model.hasPrefix("iPad") ? .pad : .phone
        #endif
    }()

    /// The one device that reads and publishes Health, writes workouts, talks to the Watch, rings
    /// alarms and writes the calendar holds.
    var isHub: Bool { self == .phone }

    /// "iPhone", "iPad", "Mac" — for sentences about where something lives ("stays on this iPad").
    var name: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .mac: "Mac"
        }
    }
}
