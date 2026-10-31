import Foundation

/// A one-off alarm is just data — no AlarmKit in it. The Mac shows them on the timeline even though
/// it can't ring one, so the model lives outside the iOS-only store that arms them.
struct OneOffAlarm: Identifiable, Codable, Hashable {
    var id = UUID()
    var fire: Date
    var label: String

    /// What the alarm says when it rings.
    var title: String {
        label.isEmpty ? "Alarm \u{00B7} \(fire.formatted(.dateTime.hour().minute()))" : label
    }
}

/// The one-off alarm list as every device keeps it: the same list everywhere (it syncs), soonest
/// first. The phone also arms each one; the others only list them.
enum OneOffAlarmList {
    /// The list with `alarm` added, or put in place of the one with its id.
    static func adding(_ alarm: OneOffAlarm, to list: [OneOffAlarm]) -> [OneOffAlarm] {
        (list.filter { $0.id != alarm.id } + [alarm]).sorted { $0.fire < $1.fire }
    }

    /// Another device's version of one alarm: added or replaced, or removed when it was deleted
    /// there (`alarm` nil). One whose time has passed is left out — it has rung, or never will.
    static func applying(_ alarm: OneOffAlarm?, id: UUID, to list: [OneOffAlarm], now: Date) -> [OneOffAlarm] {
        guard let alarm, alarm.fire > now else { return list.filter { $0.id != id } }
        return adding(alarm, to: list)
    }

    /// Each alarm encoded for `CloudControlsSync`, by id.
    static func cloudItems(_ list: [OneOffAlarm]) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        for alarm in list { items[alarm.id.uuidString] = try? encoder.encode(alarm) }
        return items
    }
}
