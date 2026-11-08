#if !BANANA_PUBLIC
import Foundation

/// The identifiers of snooze: the "…" menus' entry, the swipe, the picker's own rows. Foundation
/// only, like every `MailIdentifiers*.swift`: the UI tests compile these files too.
extension MailID {
    static let snoozeMenu = "mail.snooze"
    static let snoozeSheet = "mail.snooze.sheet"
    static let snoozeCustom = "mail.snooze.custom"
    static let snoozeCustomPicker = "mail.snooze.custom.picker"
    static let snoozeCustomDone = "mail.snooze.custom.done"
    static let unsnooze = "mail.snooze.unsnooze"
    /// A preset in a menu: "later", "tomorrow", "weekend", "monday" (MailTimePresets' ids).
    static func snoozePreset(_ id: String) -> String { "mail.snooze.preset." + id }
}

#endif
