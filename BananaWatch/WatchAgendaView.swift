import SwiftUI

struct WatchAgendaView: View {
    let onClose: () -> Void
    var previewItems: [WatchCalendarItem]? = nil
    @State private var items = WatchCalendarSnapshotStore.load()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let days = agendaDays(at: context.date)
                Group {
                    if days.isEmpty {
                        ContentUnavailableView(
                            "Nothing upcoming",
                            systemImage: "calendar",
                            description: Text("Open Banana on your iPhone to refresh your agenda."))
                    } else {
                        List(days) { day in
                            Section(day.title) {
                                ForEach(day.items) { item in
                                    NavigationLink {
                                        WatchCalendarDetailView(item: item)
                                    } label: {
                                        WatchAgendaRow(item: item, now: context.date)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Agenda")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close agenda")
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        guard previewItems == nil else { return }
        items = WatchCalendarSnapshotStore.load()
    }

    private func agendaDays(at date: Date) -> [WatchAgendaDay] {
        let calendar = Calendar.autoupdatingCurrent
        let source = previewItems ?? items
        let upcoming = WatchCalendarSnapshotStore.upcoming(from: source, at: date, limit: 8)
        let grouped = Dictionary(grouping: upcoming) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInTomorrow(day) {
                title = "Tomorrow"
            } else {
                title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            return WatchAgendaDay(date: day, title: title, items: grouped[day] ?? [])
        }
    }
}

private struct WatchAgendaDay: Identifiable {
    let date: Date
    let title: String
    let items: [WatchCalendarItem]
    var id: Date { date }
}

private struct WatchAgendaRow: View {
    let item: WatchCalendarItem
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                if item.start <= now && item.end > now {
                    Text("NOW")
                        .foregroundStyle(.orange)
                } else {
                    Text(item.start.formatted(date: .omitted, time: .shortened))
                }
                Text(item.end.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let location = item.location, !location.isEmpty {
                    Label(location, systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WatchCalendarDetailView: View {
    let item: WatchCalendarItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                Section {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }

                    Label(durationText, systemImage: "hourglass")

                    if let location = item.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                    }
                }

                if item.start <= context.date && item.end > context.date {
                    Text("Happening now")
                        .foregroundStyle(.orange)
                } else if item.start > context.date {
                    Text(relativeStart(from: context.date))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Event")
    }

    private var durationText: String {
        let minutes = max(1, Int(item.end.timeIntervalSince(item.start) / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func relativeStart(from date: Date) -> String {
        let minutes = max(1, Int(item.start.timeIntervalSince(date) / 60))
        if minutes < 60 { return "Starts in \(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "Starts in 1 hour" : "Starts in \(hours) hours"
    }
}

#if DEBUG
extension WatchCalendarItem {
    static func agendaPreviewItems(now: Date = .now) -> [WatchCalendarItem] {
        [
            WatchCalendarItem(
                id: "preview-current",
                title: "Product planning with Ana",
                start: now.addingTimeInterval(-10 * 60),
                end: now.addingTimeInterval(35 * 60),
                location: "Conference Room 3"),
            WatchCalendarItem(
                id: "preview-next",
                title: "Design review",
                start: now.addingTimeInterval(70 * 60),
                end: now.addingTimeInterval(100 * 60),
                location: "Studio 4"),
            WatchCalendarItem(
                id: "preview-later",
                title: "Dinner reservation",
                start: now.addingTimeInterval(4 * 3_600),
                end: now.addingTimeInterval(5 * 3_600),
                location: "Via Carota"),
        ]
    }
}
#endif
