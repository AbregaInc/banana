#if os(iOS)
import Combine
import Foundation
import WidgetKit

/// Keeps the widgets' agenda file current: whenever today's or tomorrow's meetings, the
/// commute legs or the calendar colours change, rewrite it and — only if what the widgets draw
/// actually changed — ask WidgetKit to reload them. Reloads are budgeted by the system, so an
/// unchanged agenda must not spend one.
@MainActor
final class WidgetAgendaPublisher {
    static let shared = WidgetAgendaPublisher()
    private var observer: AnyCancellable?

    func start(smart: SmartScheduleStore) {
        guard observer == nil else { return }
        observer = Publishers.CombineLatest4(smart.$todayMeetings, smart.$tomorrowMeetings,
                                             smart.$commuteLegs, smart.$calendarColorHex)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { today, tomorrow, legs, colors in
                let agenda = Self.agenda(meetings: today + tomorrow, legs: legs, colors: colors, now: Date())
                Task.detached(priority: .utility) {
                    guard agenda.save() else { return }
                    for kind in WidgetAgenda.widgetKinds {
                        WidgetCenter.shared.reloadTimelines(ofKind: kind)
                    }
                }
            }
    }

    nonisolated static func agenda(meetings: [MeetingInfo], legs: [NotificationService.CommuteLeg],
                                   colors: [String: String], now: Date) -> WidgetAgenda {
        var seen = Set<String>()
        let events = meetings
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
            .map { meeting -> WidgetAgenda.Event in
                let leg = legs.first { $0.title == meeting.title && abs($0.start.timeIntervalSince(meeting.start)) < 60 }
                return WidgetAgenda.Event(
                    id: meeting.eventID ?? meeting.id,
                    title: meeting.title,
                    start: meeting.start,
                    end: meeting.end ?? meeting.start.addingTimeInterval(1800),
                    colorHex: meeting.calendarID.flatMap { colors[$0] },
                    location: meeting.address,
                    isVirtual: meeting.isVirtual,
                    joinURL: meeting.joinURL,
                    leaveBy: leg?.leaveBy,
                    travelMinutes: leg?.travelMinutes,
                    isTentative: meeting.myResponse == .tentative,
                    showsAsFree: meeting.showsAsFree,
                    travelSymbol: leg?.detail?.mode.systemImage)
            }
        return WidgetAgenda(generatedAt: now, events: events)
    }
}
#endif
