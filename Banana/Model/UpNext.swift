import Foundation

/// What Today may headline as "Up next": something with a real time that hasn't come yet, and
/// isn't already done.
///
/// A task due today with no time is placed on the timeline at the moment of the last
/// recalculation — which, just after launch, is a minute in the future. It used to win "Up next"
/// for that minute and then give way, and every recalculation while the app caught up made the
/// card flip between the undated task and the real next thing.
enum UpNext {
    static func isCandidate(time: Date?, pending: Bool, now: Date) -> Bool {
        guard pending, let time else { return false }
        return time > now
    }
}
