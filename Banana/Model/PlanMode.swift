import Foundation

/// How Plan shows your time: one day, or the week. One switch, on the phone, the iPad and the
/// Mac.
///
/// There was a third, a List of what's next with overdue reminders first. Those lead today's
/// reminders line in Day now (`OutstandingReminders`), so the List said nothing Day doesn't.
/// A stored "list" reads as Day: an unknown value falls back to the default.
enum PlanMode: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        }
    }

    /// The mode once the old Week "agenda" layout is retired: whoever had Week showing that
    /// list is on Day, where what it listed for today is. Day was never affected by the setting.
    func retiringAgendaLayout(_ weekShowedAgenda: Bool) -> PlanMode {
        weekShowedAgenda && self == .week ? .day : self
    }
}
