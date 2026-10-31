import XCTest

final class WidgetAgendaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, _ startMin: Double, _ endMin: Double, leave: Double? = nil,
                       free: Bool = false) -> WidgetAgenda.Event {
        .init(id: id, title: id, start: now.addingTimeInterval(startMin * 60),
              end: now.addingTimeInterval(endMin * 60), colorHex: nil, location: nil, isVirtual: false,
              joinURL: nil, leaveBy: leave.map { now.addingTimeInterval($0 * 60) }, travelMinutes: nil,
              isTentative: false, showsAsFree: free)
    }

    func testFocusIsTheMeetingInProgressThenTheNextOne() {
        let agenda = WidgetAgenda(generatedAt: now, events: [event("later", 60, 90), event("now", -10, 20)])
        XCTAssertEqual(agenda.focus(at: now)?.id, "now")
        XCTAssertEqual(agenda.focus(at: now.addingTimeInterval(30 * 60))?.id, "later")
        XCTAssertNil(agenda.focus(at: now.addingTimeInterval(120 * 60)))
    }

    func testAFreeEventIsNeverTheFocus() {
        let agenda = WidgetAgenda(generatedAt: now, events: [event("dinner", 10, 60, free: true), event("call", 30, 40)])
        XCTAssertEqual(agenda.focus(at: now)?.id, "call")
    }

    func testTheTimelineChangesAtEveryStartEndAndLeaveBy() {
        let agenda = WidgetAgenda(generatedAt: now, events: [event("a", 30, 60, leave: 10), event("b", 60, 90)])
        XCTAssertEqual(agenda.changePoints(after: now).map { $0.timeIntervalSince(now) / 60 }, [10, 30, 60, 90])
    }

    func testEventsInAWindowOverlapIt() {
        let agenda = WidgetAgenda(generatedAt: now, events: [event("before", -120, -60), event("spans", -30, 30), event("after", 300, 330)])
        XCTAssertEqual(agenda.events(from: now, to: now.addingTimeInterval(3600)).map(\.id), ["spans"])
    }
}
