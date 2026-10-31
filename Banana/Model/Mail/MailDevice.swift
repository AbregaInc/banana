#if !BANANA_PUBLIC
import Foundation

/// Which kind of device mail is running on, as far as pacing its local work is concerned
/// (MAIL-ENGINE 4.12, 13.6).
///
/// The app already has its own idea of a device's role (`DeviceRole`), but the engine folder may
/// not name it freely (invariant 17), and what the work pace needs is narrower: a phone and an
/// iPad are treated alike, and the Mac differs. The wiring in `MailApp/` turns one into the
/// other.
///
/// Declared here, ahead of `MailEnvironment` (P23a), because `MailWorkPace` needs it long before
/// that exists.
enum MailDeviceRole: Sendable {
    case phone, pad, mac
}

/// What the device says about its power and heat, as the work pace reads it.
///
/// The three facts are the three things the pace table of 4.12 turns on: a Mac on mains runs
/// flat out; a device that is warm or in Low Power Mode does not run local passes at all. The
/// wiring fills it in from `ProcessInfo` (`isLowPowerModeEnabled`, `thermalState`) and the
/// battery; nothing here reads the device.
struct MailPower: Equatable, Sendable {
    var onMains: Bool
    var lowPowerMode: Bool
    /// `ProcessInfo.ThermalState.fair`, `.serious` or `.critical`.
    var thermalFairOrWorse: Bool
}

#endif
