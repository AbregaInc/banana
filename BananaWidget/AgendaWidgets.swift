import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AgendaEntry: TimelineEntry {
    let date: Date
    let agenda: WidgetAgenda?
}

struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: Date(), agenda: .sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        let agenda = WidgetAgenda.load() ?? (context.isPreview ? .sample(now: Date()) : nil)
        completion(AgendaEntry(date: Date(), agenda: agenda))
    }

    /// One entry now and one at every start, end and leave-by in the next day, so "next" and
    /// "in 12 min" stay right with the app closed. The app reloads the timeline when the agenda
    /// itself changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let now = Date()
        let agenda = WidgetAgenda.load()
        var dates = [now] + (agenda?.changePoints(after: now) ?? [])
        // Relative times ("in 12 min") read wrong within minutes; refresh every quarter hour
        // over the next few hours as well.
        for step in 1...16 { dates.append(now.addingTimeInterval(Double(step) * 900)) }
        let entries = Array(Set(dates)).sorted().map { AgendaEntry(date: $0, agenda: agenda) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(4 * 3600))))
    }
}

// MARK: - Shared pieces

/// How a widget names an event's time, relative to the moment the entry is drawn.
enum WidgetTime {
    static func clock(_ date: Date) -> String { TimeRangeText.time(date) }

    /// "Now · until 1:38 PM", "Leave 12:18 PM", or "12:38 PM".
    static func status(_ event: WidgetAgenda.Event, at now: Date) -> String {
        if event.start <= now { return "Now · until \(clock(event.end))" }
        if let leave = event.leaveBy, leave > now { return "\(clock(event.start)) · leave \(clock(leave))" }
        return clock(event.start)
    }

    /// The line under a title: where it is, or how to get there.
    static func detail(_ event: WidgetAgenda.Event) -> String? {
        if event.isVirtual { return event.joinURL != nil ? "Video call" : nil }
        return event.location?.components(separatedBy: ",").first
    }
}

/// The calendar's colour as a slim bar, the way the app's grid marks every event.
struct CalendarBar: View {
    let hex: String?
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(CalendarColor.color(hex: hex) ?? .secondary)
            .frame(width: 3)
    }
}

/// Upcoming events from `now`: anything not over yet, free ones included but never first.
private func upcoming(_ agenda: WidgetAgenda?, at now: Date) -> [WidgetAgenda.Event] {
    guard let agenda else { return [] }
    let focus = agenda.focus(at: now)
    let rest = agenda.events.filter { $0.end > now && $0.id != focus?.id }.sorted { $0.start < $1.start }
    return (focus.map { [$0] } ?? []) + rest
}

// MARK: - Lock Screen and small: the next meeting

struct NextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BananaNextMeeting", provider: AgendaProvider()) { entry in
            FamilyReader { NextMeetingView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Next meeting")
        .description("What's next, and when to leave for it.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall])
    }
}

/// Hands the widget family to a view as a plain value, so the same views can be drawn by the
/// app (a debug gallery) where the environment value cannot be set.
struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family) }
}

struct NextMeetingView: View {
    let entry: AgendaEntry
    let family: WidgetFamily

    var body: some View {
        let event = entry.agenda?.focus(at: entry.date)
        switch family {
        case .accessoryInline: inline(event)
        case .accessoryCircular: circular(event)
        case .systemSmall: small(event)
        default: rectangular(event)
        }
    }

    @ViewBuilder private func inline(_ event: WidgetAgenda.Event?) -> some View {
        if let event {
            if let leave = event.leaveBy, leave > entry.date, event.start > entry.date {
                Label("Leave \(WidgetTime.clock(leave)) · \(event.title)", systemImage: event.travelSymbol ?? "car.fill")
            } else {
                Label("\(WidgetTime.clock(event.start)) \(event.title)", systemImage: "calendar")
            }
        } else {
            Label("No more meetings", systemImage: "calendar")
        }
    }

    /// Three lines: when (and when to leave), then the title on the two that remain — so a long
    /// title gets two lines instead of being cut to one.
    @ViewBuilder private func rectangular(_ event: WidgetAgenda.Event?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event {
                Text(WidgetTime.status(event, at: entry.date))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .widgetAccentable()
                Text(event.title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            } else {
                Text("Banana").font(.caption.weight(.semibold)).widgetAccentable()
                Text("No more meetings").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func circular(_ event: WidgetAgenda.Event?) -> some View {
        if let event {
            let leave = event.leaveBy.flatMap { $0 > entry.date && event.start > entry.date ? $0 : nil }
            VStack(spacing: 0) {
                Image(systemName: leave != nil ? (event.travelSymbol ?? "car.fill") : "calendar").font(.caption)
                Text(TimeRangeText.clockOnly(leave ?? event.start))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
        } else {
            Image(systemName: "calendar")
        }
    }

    @ViewBuilder private func small(_ event: WidgetAgenda.Event?) -> some View {
        if let event {
            let isNow = event.start <= entry.date
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(CalendarColor.color(hex: event.colorHex) ?? .secondary).frame(width: 7, height: 7)
                    Text(isNow ? "NOW" : "NEXT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DS.Palette.accent)
                    Spacer(minLength: 4)
                    Text(isNow ? "until \(WidgetTime.clock(event.end))" : WidgetTime.clock(event.start))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // Long titles shrink before they truncate and take every line the tile has; the
                // rows around them are single lines and give way first.
                Text(event.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let leave = event.leaveBy, leave > entry.date, !isNow {
                    Label("Leave \(WidgetTime.clock(leave))", systemImage: event.travelSymbol ?? "car.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.travel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if let detail = WidgetTime.detail(event) {
                    Label(detail, systemImage: event.isVirtual ? "video.fill" : "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("TODAY").font(.caption2.weight(.bold)).foregroundStyle(DS.Palette.accent)
                Text("No more meetings").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Home Screen: what's next, as an agenda

/// Kind kept as "BananaDayGrid" so widgets already placed keep working. It was a scaled-down
/// time grid; at widget size that spent most of its space on empty hours and cut off short
/// events, so it is an agenda now: the next event large, the ones after it as rows.
struct DayGridWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BananaDayGrid", provider: AgendaProvider()) { entry in
            FamilyReader { AgendaListView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Up next")
        .description("Your next meetings, and when to leave.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct AgendaListView: View {
    let entry: AgendaEntry
    let family: WidgetFamily

    var body: some View {
        let events = upcoming(entry.agenda, at: entry.date)
        if let first = events.first {
            if family == .systemLarge { large(first, rest: Array(events.dropFirst())) }
            else { medium(first, rest: Array(events.dropFirst().prefix(3))) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.date.formatted(.dateTime.weekday(.wide).day()).uppercased())
                    .font(.caption2.weight(.bold)).foregroundStyle(DS.Palette.accent)
                Text("No more meetings").font(.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func medium(_ first: WidgetAgenda.Event, rest: [WidgetAgenda.Event]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // The next event fills its half top to bottom: title up top, leave-by (the thing to
            // act on) pinned to the bottom edge.
            HStack(alignment: .top, spacing: 8) {
                CalendarBar(hex: first.colorHex)
                VStack(alignment: .leading, spacing: 3) {
                    label(first)
                    Text(first.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                    Text(first.start <= entry.date ? "until \(WidgetTime.clock(first.end))" : WidgetTime.clock(first.start))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    footer(first)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !rest.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rest.prefix(3)) { row($0, titleLines: rest.count < 3 ? 2 : 1) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func label(_ event: WidgetAgenda.Event) -> some View {
        Text(event.start <= entry.date ? "NOW" : "NEXT")
            .font(.caption2.weight(.bold))
            .foregroundStyle(DS.Palette.accent)
    }

    /// Leave-by when there is one, otherwise where it is.
    @ViewBuilder private func footer(_ event: WidgetAgenda.Event) -> some View {
        if let leave = event.leaveBy, leave > entry.date, event.start > entry.date {
            Label("Leave \(WidgetTime.clock(leave))", systemImage: event.travelSymbol ?? "car.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.travel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let detail = WidgetTime.detail(event) {
            Label(detail, systemImage: event.isVirtual ? "video.fill" : "mappin")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func large(_ first: WidgetAgenda.Event, rest: [WidgetAgenda.Event]) -> some View {
        let calendar = Calendar.current
        // Five rows is what the large tile holds under the next event without clipping.
        let today = rest.filter { calendar.isDate($0.start, inSameDayAs: entry.date) }.prefix(5)
        let later = rest.filter { !calendar.isDate($0.start, inSameDayAs: entry.date) }.prefix(max(0, 4 - today.count))
        return VStack(alignment: .leading, spacing: 10) {
            Text(entry.date.formatted(.dateTime.weekday(.wide).month().day()).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            hero(first, titleLines: 2)
            Divider()
            ForEach(Array(today)) { row($0, titleLines: 1) }
            if !later.isEmpty {
                Text("TOMORROW").font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(Array(later)) { row($0, titleLines: 1) }
            }
            Spacer(minLength: 0)
        }
    }

    private func hero(_ event: WidgetAgenda.Event, titleLines: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            CalendarBar(hex: event.colorHex)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.start <= entry.date ? "NOW" : "NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DS.Palette.accent)
                Text(event.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(titleLines)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                Text(WidgetTime.status(event, at: entry.date))
                    .font(.caption)
                    .foregroundStyle(event.leaveBy.map { $0 > entry.date } == true ? DS.Palette.travel : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail = WidgetTime.detail(event) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ event: WidgetAgenda.Event, titleLines: Int) -> some View {
        HStack(alignment: .top, spacing: 7) {
            CalendarBar(hex: event.colorHex).frame(height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(WidgetTime.clock(event.start))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(titleLines)
                    .foregroundStyle(event.showsAsFree ? .secondary : .primary)
            }
        }
        .opacity(event.isTentative ? 0.75 : 1)
    }
}

extension WidgetAgenda {
    /// For the gallery and previews.
    static func sample(now: Date) -> WidgetAgenda {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        func event(_ id: String, _ title: String, _ start: Double, _ minutes: Double, _ color: String,
                   location: String? = nil, virtual: Bool = false, leave: Double? = nil,
                   tentative: Bool = false, free: Bool = false) -> Event {
            .init(id: id, title: title, start: at(start), end: at(start + minutes), colorHex: color,
                  location: location, isVirtual: virtual,
                  joinURL: virtual ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                  leaveBy: leave.map(at), travelMinutes: leave.map { Int(start - $0) },
                  isTentative: tentative, showsAsFree: free)
        }
        return WidgetAgenda(generatedAt: now, events: [
            event("1", "Quarterly planning review with the product and design leads", 25, 60, "#1A73E8",
                  location: "500 Howard St, San Francisco", leave: 5),
            event("2", "1:1 with Sam", 120, 30, "#33B679", virtual: true, tentative: true),
            event("3", "Lunch with Maya", 165, 60, "#F4511E", location: "Tartine, 18th St"),
            event("4", "Board prep", 240, 45, "#1A73E8", virtual: true),
            event("5", "Dinner", 330, 90, "#F4511E", free: true),
            event("6", "Morning run", 60 * 20, 60, "#8E24AA"),
            event("7", "Design sync", 60 * 23, 30, "#1A73E8", virtual: true),
        ])
    }
}

#if DEBUG && os(iOS)
/// `--widgets`: every calendar widget at its real size, drawn from the sample agenda (or the
/// real one, when the app has written it), so they can be screenshotted in the Simulator.
struct WidgetGalleryView: View {
    var body: some View {
        let now = Date()
        let entry = AgendaEntry(date: now, agenda: WidgetAgenda.load() ?? .sample(now: now))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // `--home-only` leaves the Lock Screen out so the large widget fits one screenshot.
                if !ProcessInfo.processInfo.arguments.contains("--home-only") {
                    Text("Lock Screen").font(.headline)
                    HStack(spacing: 12) {
                        lock { NextMeetingView(entry: entry, family: .accessoryRectangular) }
                            .frame(width: 172, height: 76)
                        lock { NextMeetingView(entry: entry, family: .accessoryCircular) }
                            .frame(width: 76, height: 76)
                            .clipShape(Circle())
                    }
                    lock { NextMeetingView(entry: entry, family: .accessoryInline) }
                        .frame(width: 300, height: 26)
                }
                Text("Home Screen").font(.headline)
                home { NextMeetingView(entry: entry, family: .systemSmall) }
                    .frame(width: 170, height: 170)
                home { AgendaListView(entry: entry, family: .systemMedium) }
                    .frame(width: 364, height: 170)
                home { AgendaListView(entry: entry, family: .systemLarge) }
                    .frame(width: 364, height: 382)
            }
            .padding()
        }
        // A wallpaper behind everything, as on a real Lock and Home Screen: widgets are judged
        // against it, not against a flat black page.
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.35),
                                            Color(red: 0.35, green: 0.18, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    /// Lock Screen widgets have no tile: white text straight on the wallpaper.
    private func lock(@ViewBuilder _ content: () -> some View) -> some View {
        content().foregroundStyle(.white)
    }

    /// Home Screen widgets: the system's 16 pt content margin inside a rounded tile.
    private func home(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
