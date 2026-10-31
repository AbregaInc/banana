import Foundation
import CoreGraphics

/// Reminders ticked (or unticked) a moment ago, until a read made after the tick is in.
///
/// A tick shows at once, and it has to show everywhere a reminder is drawn and in whatever is
/// published meanwhile. Two things used to undo that. The calendar grids draw from cached windows,
/// which nothing told about the tick, so a reminder ticked on the Mac's calendar sat unticked for
/// the seconds a full read takes. And a read already under way when the tick was made, holding
/// Reminders' older answer, was published over it. So the ticks are kept here and laid over both
/// (`applied`), and when they retire, whatever a later read still disagrees about goes back to
/// what that read said (`disagreements`): a tick Reminders refused doesn't stay ticked.
///
/// Generic over the item, as the tests have no timeline type. Pure.
enum TaskTicks {
    struct Tick: Equatable {
        var completed: Bool
        /// One instance of a repeating reminder; nil for every item of the reminder.
        var onlyOccurrence: String?
        var at: Date?
    }

    /// Whether a tick is about this item.
    static func covers(_ tick: Tick, itemID: String) -> Bool {
        tick.onlyOccurrence == nil || tick.onlyOccurrence == itemID
    }

    /// `items` with every tick laid over them. `ticks` is keyed by reminder id.
    static func applied<Item>(to items: [Item], ticks: [String: Tick],
                              reminderID: (Item) -> String?, id: (Item) -> String,
                              completed: (Item) -> Bool,
                              setting: (Item, Bool, Date?) -> Item) -> [Item] {
        guard !ticks.isEmpty else { return items }
        return items.map { item in
            guard let reminder = reminderID(item), let tick = ticks[reminder],
                  covers(tick, itemID: id(item)), completed(item) != tick.completed else { return item }
            return setting(item, tick.completed, tick.at)
        }
    }

    /// The items of a read that the ticks would change: what to go back to if the ticks retire
    /// and the read still says otherwise. Keyed by item id.
    static func disagreements<Item>(in read: [Item], ticks: [String: Tick],
                                    reminderID: (Item) -> String?, id: (Item) -> String,
                                    completed: (Item) -> Bool) -> [String: Item] {
        guard !ticks.isEmpty else { return [:] }
        var result: [String: Item] = [:]
        for item in read {
            guard let reminder = reminderID(item), let tick = ticks[reminder],
                  covers(tick, itemID: id(item)), completed(item) != tick.completed else { continue }
            result[id(item)] = item
        }
        return result
    }

    // MARK: Undo

    /// The ticks a finished read retires, and the ones that stay laid over it: a tick whose write
    /// is still waiting (held while its toast offers Undo, or queued) can't be judged by a read
    /// yet. Retired then, Reminders' "not done" would un-tick it on screen before it was written.
    static func retiring(_ ticks: [String: Tick], waiting: Set<String>) -> (retire: [String: Tick], keep: [String: Tick]) {
        (ticks.filter { !waiting.contains($0.key) }, ticks.filter { waiting.contains($0.key) })
    }

    /// Whether a reminder's block on the grid has its own tick target. A tap never completes a
    /// reminder unless it lands on a circle there is room to aim at: a block narrower than this
    /// (a phone's seven-day week) opens as a whole, and is ticked from what it opens or its menu.
    static func blockHasTickTarget(width: CGFloat) -> Bool { width >= tickTargetWidth + 50 }
    static let tickTargetWidth: CGFloat = 30

    /// The toast after "Missed it".
    static func missedMessage(title: String) -> String {
        "Missed \u{201C}\(shortened(title))\u{201D}"
    }

    /// The toast after a tick, which is where it can be taken back.
    static func message(title: String, completed: Bool) -> String {
        let shown = shortened(title)
        return completed ? "Completed \u{201C}\(shown)\u{201D}" : "\u{201C}\(shown)\u{201D} is not done"
    }

    private static func shortened(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.count > 40 ? String(name.prefix(39)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : name
    }
}
