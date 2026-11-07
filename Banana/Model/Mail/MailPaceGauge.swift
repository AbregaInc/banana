#if !BANANA_PUBLIC
import Foundation

/// What `MailWorkPace` needs to know right now, readable from any thread: whether Mail is on
/// screen (or a push's short background window is open), and the device's power and heat.
/// Thermal state and Low Power Mode are read from `ProcessInfo`; whether a Mac is on mains is
/// told by the app (`onMains`), and taken as "no" until it is, which paces a Mac to a fifth of a
/// core rather than letting it run flat out unasked.
///
/// A push window counts as Mail being in use: it is bounded (about 25 s, a handful of new
/// messages), and preparing what it brought is what keeps the next open from waiting.
final class MailPaceGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = false
    private var windows = 0
    private var mains: @Sendable () -> Bool = { false }

    func setVisible(_ value: Bool) { lock.withLock { visible = value } }
    func enterWindow() { lock.withLock { windows += 1 } }
    func leaveWindow() { lock.withLock { windows = max(0, windows - 1) } }
    func setOnMains(_ reader: @escaping @Sendable () -> Bool) { lock.withLock { mains = reader } }

    func pace() -> MailWorkPace {
        let (inUse, onMains) = lock.withLock { (visible || windows > 0, mains) }
        let info = ProcessInfo.processInfo
        let power = MailPower(onMains: onMains(), lowPowerMode: info.isLowPowerModeEnabled,
                              thermalFairOrWorse: info.thermalState != .nominal)
        #if os(macOS)
        let role = MailDeviceRole.mac
        #else
        let role = MailDeviceRole.phone
        #endif
        return MailWorkPace.current(role: role, power: power, insideOvernightTask: false, mailVisible: inUse, appActive: inUse)
    }
}

#endif
