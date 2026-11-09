import Foundation

/// What something done each day is due around, instead of only a clock time
/// (docs/design/ANCHORED-TIMING.md): a moment, before or after it by some minutes, and what to do
/// when the moment doesn't come. The item's own time is the fallback.
struct TimingAnchor: Codable, Hashable, Sendable {
    enum Moment: Codable, Hashable, Sendable {
        /// A workout: Health's, or one recorded on the Watch.
        case workout
        /// Waking, from last night's sleep.
        case wake
        /// A meal logged — breakfast, lunch, dinner (a `MealTextPart` raw value), or nil for the
        /// first meal of the day.
        case meal(String?)
        /// Another reminder ticked. Its stable id, and its title (a completed copy of a repeating
        /// reminder can carry a different id).
        case reminder(id: String, title: String)
        /// Another Taken item marked taken.
        case dose(id: UUID, name: String)
        /// A calendar event whose title has one of these words.
        case event([String])
    }

    enum Relation: String, Codable, Hashable, Sendable { case before, after }

    enum Fallback: String, Codable, Hashable, Sendable {
        /// At the item's own time.
        case usualTime
        /// Not that day.
        case skip
    }

    var moment: Moment
    var relation: Relation = .after
    /// How long after (or before) it. 0 is right away.
    var minutes: Int = 0
    var fallback: Fallback = .usualTime

    init(moment: Moment, relation: Relation = .after, minutes: Int = 0, fallback: Fallback = .usualTime) {
        self.moment = moment
        self.relation = relation
        self.minutes = max(0, minutes)
        self.fallback = fallback
    }
}
