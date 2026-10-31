#if os(iOS)
// AlarmKit is iPhone-only. Waking you up is a phone's job — a Mac that's asleep can't ring.

import AlarmKit
import Foundation

/// Metadata attached to every Banana alarm.
/// AlarmKit requires a concrete `AlarmMetadata` type; we don't need any extra
/// per-alarm data, so this is intentionally empty. `Codable`/`Hashable`/`Sendable`
/// are synthesized automatically for an empty struct.
struct BananaMetadata: AlarmMetadata {
    init() {}
}

/// Convenience alias so the app and the widget extension share one attributes type.
typealias BananaAlarmAttributes = AlarmAttributes<BananaMetadata>
#endif
