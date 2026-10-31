import SwiftUI

/// The demo supplies data and commands; the live calendar's lane planner, artwork and native
/// collection view still own overlap geometry, accessibility and cell reuse.
struct DemoCalendarView: View {
    @ObservedObject var session: DemoSession
    @Binding var editing: DemoEvent?
    @State private var week = false
    @State private var offset = 0
    @State private var calendars = false
    @State private var hourHeight: CGFloat = 64
    @State private var filter = LiveFilter(scope: "plan")

    var body: some View {
        if let workspace = session.workspace {
            VStack(spacing: 8) {
                HStack {
                    Button { offset -= week ? 3 : 1 } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous sample day")
                    Spacer()
                    Text(day(workspace).formatted(.dateTime.weekday().month().day())).font(.headline)
                    Spacer()
                    Button { offset += week ? 3 : 1 } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next sample day")
                }.padding(.horizontal)
                Picker("View", selection: $week) { Text("Day").tag(false); Text("Week").tag(true) }
                    .pickerStyle(.segmented).padding(.horizontal)
                LiveFilterSearch(scope: "plan", sources: workspace.calendars.map { .init(id: $0.id, name: $0.title) }, filter: $filter)
                    .padding(.horizontal)
                GeometryReader { geometry in
                    calendar(workspace, width: geometry.size.width)
                }.accessibilityIdentifier("demo.calendar")
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { calendars = true } label: { Image(systemName: "calendar.badge.checkmark") }.accessibilityLabel("Sample calendar visibility")
                    Button { editing = newEvent(workspace) } label: { Image(systemName: "plus") }.accessibilityLabel("Add sample event")
                }
            }
            .sheet(isPresented: $calendars) {
                NavigationStack {
                    Form {
                        ForEach(workspace.calendars) { calendar in
                            Toggle(calendar.title, isOn: Binding(get: {
                                session.workspace?.calendars.first(where: { $0.id == calendar.id })?.visible ?? false
                            }, set: { value in Task { await session.perform(.calendarVisible(calendar.id, value)) } }))
                            .accessibilityIdentifier("demo.calendar.visible.\(calendar.id)")
                        }
                    }
                    .navigationTitle("Calendar visibility")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { calendars = false } } }
                }.frame(minWidth: 300, minHeight: 300)
            }
        }
    }

    private func day(_ workspace: DemoWorkspace) -> Date {
        workspace.calendar.date(byAdding: .day, value: offset, to: workspace.anchor) ?? workspace.anchor
    }

    private func newEvent(_ workspace: DemoWorkspace) -> DemoEvent {
        let start = workspace.calendar.date(bySettingHour: 13, minute: 0, second: 0, of: day(workspace))!
        return DemoEvent(id: UUID(), calendarID: "personal", title: "", start: start, end: start.addingTimeInterval(3600))
    }

    private func color(_ id: String) -> Color {
        switch id { case "work": .blue; case "fitness": .orange; case "shared": .gray; default: .purple }
    }

    private func matching(_ event: DemoEvent, workspace: DemoWorkspace) -> Bool {
        guard filter.predicate(now: workspace.anchor, calendar: workspace.calendar)(event.start, event.title + " " + event.location, "meeting", nil) else { return false }
        return filter.terms.filter { $0.field == "calendar" }.allSatisfy { $0.op == "not" ? event.calendarID != $0.value : event.calendarID == $0.value }
    }

    private func calendar(_ workspace: DemoWorkspace, width: CGFloat) -> some View {
        let days = (0..<(week ? (width >= 700 ? 7 : 3) : 1)).map { workspace.calendar.date(byAdding: .day, value: $0, to: day(workspace))! }
        let gutter: CGFloat = 36, column = max(1, (width - gutter) / CGFloat(days.count))
        var placements: [(DemoEvent, CGRect, String)] = []
        for (columnIndex, date) in days.enumerated() {
            let events = workspace.events(on: date).filter { matching($0, workspace: workspace) }
            let range = workspace.calendar.dateInterval(of: .day, for: date)!
            let lanes = CalendarLanePlan.make(events.map { .init(id: $0.id.uuidString, start: max($0.start, range.start), end: min($0.end, range.end)) })
            for lane in lanes {
                let event = events[lane.index], start = workspace.calendar.startOfDay(for: date)
                let from = max(event.start, range.start), to = min(event.end, range.end)
                let minutes = workspace.calendar.dateComponents([.hour, .minute], from: start, to: from)
                let y = CGFloat((minutes.hour ?? 0) * 60 + (minutes.minute ?? 0)) / 60 * hourHeight
                let cellWidth = column / CGFloat(lane.laneCount)
                placements.append((event, CGRect(x: gutter + CGFloat(columnIndex) * column + CGFloat(lane.lane) * cellWidth + 2,
                    y: y, width: cellWidth * CGFloat(lane.laneSpan) - 4,
                    height: max(24, CGFloat(to.timeIntervalSince(from) / 3600) * hourHeight)),
                    event.id.uuidString + "|" + String(event.start.timeIntervalSince1970) + "|" + String(columnIndex)))
            }
        }
        let background = AnyView(ZStack(alignment: .topLeading) {
            CalendarHourLines(hourHeight: hourHeight, hourColor: .secondary.opacity(0.2), halfHourColor: .secondary.opacity(0.08), usesCanvas: false)
            ForEach(0..<24) { hour in
                Text(hour == 0 ? "12 AM" : hour < 12 ? "\(hour) AM" : hour == 12 ? "12 PM" : "\(hour - 12) PM")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: gutter - 4, alignment: .trailing).offset(y: CGFloat(hour) * hourHeight)
            }
        }.frame(width: width, height: 24 * hourHeight))
        #if os(iOS)
        let items = placements.map { event, frame, identity in
            CalendarViewportItem(id: identity, frame: frame,
                move: workspace.calendars.first(where: { $0.id == event.calendarID })?.readOnly == true ? nil : CalendarViewportMove(
                    id: event.id.uuidString, columnWidth: column, changed: { _ in }, ended: { translation in
                        let minutes = (Double(translation.height / hourHeight) * 60 / 15).rounded() * 15
                        let date = event.start.addingTimeInterval(minutes * 60)
                        Task { await session.perform(.moveEvent(event.id, date)) }
                        return true
                    }, cancelled: {})) { AnyView(tile(event, height: frame.height)) }
        }
        return AnyView(DirectionalDayScrollView(resetToken: "demo-\(offset)-\(week)", contentHeight: 24 * hourHeight,
            initialOffset: 8 * hourHeight, onHorizontalSwipe: { next in offset += next ? 1 : -1 }, canBeginSwipe: { true },
            onVerticalOffset: { _ in }, canBeginCreate: { _ in false }, onCreateChanged: { _, _ in }, onCreateEnded: { _, _ in },
            onCreateCancelled: {}, hourHeight: hourHeight, hourHeightRange: 44...100,
            onZoomChanged: { hourHeight = $0 }, onZoomEnded: { hourHeight = $0 }, nativeItems: items, content: background))
        #else
        let items = placements.map { event, frame, identity in
            CalendarMacViewportItem(id: identity, frame: frame) { AnyView(tile(event, height: frame.height)) }
        }
        return AnyView(CalendarMacCollectionViewport(items: items, contentSize: CGSize(width: width, height: 24 * hourHeight), background: background,
            initialOffset: 8 * hourHeight, onOffset: { _ in }))
        #endif
    }

    private var artworkLayout: CalendarEventArtwork.Layout {
        #if os(macOS)
        .desktop
        #else
        .mobile
        #endif
    }

    private func tile(_ event: DemoEvent, height: CGFloat) -> some View {
        let tint = color(event.calendarID)
        let paint = CalendarEventPaint(title: event.title, start: event.start,
            startText: event.start.formatted(date: .omitted, time: .shortened),
            timeRange: event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened),
            icon: "calendar", tint: tint, ribbons: [tint], location: event.location.isEmpty ? nil : event.location)
        return Button { editing = event } label: {
            CalendarEventArtwork(paint: paint, height: height, layout: artworkLayout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(event.title), \(event.start.formatted(date: .omitted, time: .shortened))")
            .accessibilityIdentifier("demo.event.\(event.id.uuidString)")
    }
}
