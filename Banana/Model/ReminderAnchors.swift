import Combine
import Foundation

/// The moments Apple Reminders are due around (`TimingAnchor`, docs/design/ANCHORED-TIMING.md).
/// Reminders has nowhere to keep one, so Banana does: by the reminder's stable id (the same on
/// every device), with its title as a second key — a completed copy of a repeating reminder can
/// carry another id. In iCloud key-value storage, so a rule set on the phone holds on the Mac.
@MainActor
final class ReminderAnchors: ObservableObject {
    static let shared = ReminderAnchors()

    private static let key = "reminderAnchors.v1"
    private static let usualKey = "reminderAnchors.usual.v1"
    private var store: LegacyKVS { .shared }
    @Published private(set) var rules: [String: TimingAnchor] = [:]
    /// Each tied reminder's own time of day, in minutes: what it's due at when its moment doesn't
    /// come. Kept because Banana moves the reminder's due time in Reminders on the day, and a
    /// repeating reminder moved takes the whole series with it — the next day is put back to this.
    @Published private(set) var usual: [String: Int] = [:]
    private var observer: NSObjectProtocol?

    init() {
        rules = Self.decode(store.data(forKey: Self.key) ?? UserDefaults.standard.data(forKey: Self.key))
        usual = (store.dictionary(forKey: Self.usualKey) as? [String: Int])
            ?? (UserDefaults.standard.dictionary(forKey: Self.usualKey) as? [String: Int]) ?? [:]
        observer = LegacyKVS.observeExternalChanges(tier: .personal) {
            let shared = ReminderAnchors.shared
            let rules = shared.rules, usual = shared.usual
            shared.rules = Self.decode(shared.store.data(forKey: Self.key))
            shared.usual = (shared.store.dictionary(forKey: Self.usualKey) as? [String: Int]) ?? shared.usual
            // Late arrivals for the data platform (this runs as one, `LegacyKVS`).
            SyncReport.changed(Self.syncType, SyncReport.diff(rules, shared.rules).changed)
            SyncReport.changed(Self.syncUsualType, SyncReport.diff(usual, shared.usual).changed)
        }
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `KeyValueAdapters`): one record per key

    static let syncType = "plan.reminderAnchor"
    static let syncUsualType = "plan.reminderAnchorUsual"

    /// Other devices' rules (nil: removed there), kept the usual way.
    func applySynced(rules changes: [String: TimingAnchor?]) {
        var next = rules
        for (key, anchor) in changes { next[key] = anchor }
        guard next != rules else { return }
        rules = next
        let data = try? JSONEncoder().encode(next)
        store.set(data, forKey: Self.key)
        UserDefaults.standard.set(data, forKey: Self.key)
        AnchoredTimingHub.shared.refreshSoon()
    }

    func applySynced(usual changes: [String: Int?]) {
        var next = usual
        for (key, minutes) in changes { next[key] = minutes }
        guard next != usual else { return }
        usual = next
        store.set(next, forKey: Self.usualKey)
        UserDefaults.standard.set(next, forKey: Self.usualKey)
    }

    /// A reminder's moment, by its stable id, else its title.
    func anchor(externalID: String?, title: String) -> TimingAnchor? {
        if let externalID, let rule = rules["id:" + externalID] { return rule }
        return rules["title:" + title.lowercased()]
    }

    /// Its own time of day, in minutes after midnight, if known.
    func usualMinutes(externalID: String?, title: String) -> Int? {
        if let externalID, let minutes = usual["id:" + externalID] { return minutes }
        return usual["title:" + title.lowercased()]
    }

    /// Remembers its own time of day — when tied, or the first time a tied reminder is seen.
    func setUsual(_ minutes: Int, externalID: String?, title: String) {
        var next = usual
        for key in Self.keys(externalID: externalID, title: title) { next[key] = minutes }
        guard next != usual else { return }
        let changed = SyncReport.diff(usual, next).changed
        usual = next
        store.set(next, forKey: Self.usualKey)
        UserDefaults.standard.set(next, forKey: Self.usualKey)
        SyncReport.changed(Self.syncUsualType, changed)
    }

    private static func keys(externalID: String?, title: String) -> [String] {
        [externalID.map { "id:" + $0 }, "title:" + title.lowercased()].compactMap { $0 }
    }

    /// Ties a reminder to a moment, or (nil) back to its time. `usualMinutes`: its own time of
    /// day, when the caller knows it; otherwise it's noted the first time the reminder is seen.
    func set(_ anchor: TimingAnchor?, externalID: String?, title: String, usualMinutes: Int? = nil) {
        if let usualMinutes { setUsual(usualMinutes, externalID: externalID, title: title) }
        var next = rules
        for key in Self.keys(externalID: externalID, title: title) {
            next[key] = anchor
        }
        let (changed, gone) = SyncReport.diff(rules, next)
        rules = next
        SyncReport.changed(Self.syncType, changed)
        SyncReport.deleted(Self.syncType, gone)
        let data = try? JSONEncoder().encode(next)
        store.set(data, forKey: Self.key)
        UserDefaults.standard.set(data, forKey: Self.key)
        AnchoredTimingHub.shared.refreshSoon()
    }

    /// Tolerant: one rule a newer build wrote can't cost the rest.
    private static func decode(_ data: Data?) -> [String: TimingAnchor] {
        guard let data, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var rules: [String: TimingAnchor] = [:]
        for (key, value) in raw {
            guard let json = try? JSONSerialization.data(withJSONObject: value),
                  let anchor = try? JSONDecoder().decode(TimingAnchor.self, from: json) else { continue }
            rules[key] = anchor
        }
        return rules
    }
}
