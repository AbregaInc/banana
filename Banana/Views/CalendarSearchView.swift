import SwiftUI

struct CalendarSearchButton: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "magnifyingglass") }
            .accessibilityLabel("Search calendar")
            .accessibilityIdentifier("calendar.search.open")
            .help("Search Google Calendar")
            .sheet(isPresented: $showing) { CalendarSearchView() }
    }
}

/// One provider page stays in memory. Going forward/back refetches that page, so
/// opening an edited event never turns a retained result cache into a second truth.
private struct CalendarSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var smart: SmartScheduleStore
    @State private var filter = LiveFilter(scope: "plan")
    @ObservedObject private var google = GoogleCalendarService.shared
    @State private var start = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var end = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    @State private var page: GoogleCalendarService.SearchPage?
    @State private var cursor: CalendarSearchCursor?
    @State private var history: [CalendarSearchCursor?] = []
    @State private var loading = false
    @State private var failed = false
    @State private var revision = 0
    @State private var selected: CalendarEventSheet?

    private var query: CalendarSearchQuery {
        CalendarSearchQuery(text: filter.text, start: filter.interval(calendar: .app)?.start ?? Calendar.current.startOfDay(for: start),
                            end: filter.interval(calendar: .app)?.end ?? Calendar.current.startOfDay(for: end),
                            excludedCalendarIDs: smart.settings.excludedCalendarIDs, filter: filter)
    }
    private struct Request: Hashable {
        var query: CalendarSearchQuery
        var cursor: CalendarSearchCursor?
        var revision: Int
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LiveFilterSearch(scope: "plan", sources: google.calendars.filter { !$0.isDeleted && !$0.isHidden && !smart.settings.excludedCalendarIDs.contains(GoogleCalendarService.calendarInfoID($0.id)) }.flatMap { [LiveFilterParser.Source(id: $0.id, name: $0.displayTitle), .init(id: $0.id, name: "\($0.displayTitle) (\($0.accountEmail))")] }, filter: $filter)
                }
                if filter.value("date") == nil { Section {
                    DisclosureGroup {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("Until", selection: $end, displayedComponents: .date)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Date range", systemImage: "calendar")
                            Text("\(start.formatted(.dateTime.month(.abbreviated).day().year())) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("calendar.search.dates")
                } footer: {
                    Text("Searches your visible Google calendars. Internet connection required.")
                } }
                if !query.isValid {
                    ContentUnavailableView("Search events", systemImage: "magnifyingglass",
                        description: Text(!filter.issues.isEmpty ? filter.issues.joined(separator: " ") : query.start >= query.end ? "Choose an end date after the start date." : "Find events by title, location or description."))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if failed {
                    ContentUnavailableView {
                        Label("Couldn’t search calendars", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and Google account, then try again.")
                    } actions: {
                        Button("Try again") { cursor = nil; history = []; revision += 1 }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if loading {
                    HStack {
                        Spacer()
                        ProgressView("Searching…")
                        Spacer()
                    }
                    .padding(.vertical)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if let page {
                    Section(page.calendarTitle ?? "Events") {
                        ForEach(page.events) { event in
                            Button {
                                selected = CalendarEventSheet(googleMeeting: MeetingInfo(start: event.start,
                                    end: event.end, coordinate: nil, address: event.location, isVirtual: false,
                                    title: event.title, eventID: event.id, joinURL: nil, platform: nil,
                                    calendarID: event.calendarInfoID, isAllDay: event.isAllDay))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: event.isAllDay ? "calendar" : "calendar.badge.clock")
                                        .foregroundStyle(.tint)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(event.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(event.start, format: event.isAllDay ? .dateTime.year().month().day() : .dateTime.year().month().day().hour().minute())
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        if !event.location.isEmpty {
                                            Text(event.location).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if page.events.isEmpty {
                            ContentUnavailableView.search(text: filter.text)
                                .listRowSeparator(.hidden)
                        }
                    }
                    if !history.isEmpty || page.next != nil {
                        Section {
                            HStack {
                                Button("Previous", systemImage: "chevron.left") { cursor = history.removeLast() }
                                    .disabled(history.isEmpty || loading)
                                Spacer()
                                Button("Next", systemImage: "chevron.right") { history.append(cursor); cursor = page.next }
                                    .disabled(page.next == nil || loading)
                            }
                        } footer: {
                            if page.events.isEmpty, page.next != nil {
                                Text("Continue to search the next page or calendar.")
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("calendar.search.results")
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #else
            #endif
            .navigationTitle("Filter Calendar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .onChange(of: query) { _, _ in cursor = nil; history = []; page = nil }
            .task(id: Request(query: query, cursor: cursor, revision: revision)) {
                let request = query
                let requestedCursor = cursor
                failed = false
                guard request.isValid else { loading = false; page = nil; return }
                loading = true
                page = nil
                do {
                    var result = try await GoogleCalendarService.shared.search(request, after: requestedCursor)
                    // A predicate can remove every event in a provider page. Continue automatically
                    // so an empty first calendar never asks for a click to find matches in another.
                    // Only one page is retained, and a changed sentence cancels the walk.
                    while result.events.isEmpty, let next = result.next {
                        try Task.checkCancellation()
                        result = try await GoogleCalendarService.shared.search(request, after: next)
                    }
                    try Task.checkCancellation()
                    page = result; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true; loading = false
                }
            }
            .sheet(item: $selected, onDismiss: { revision += 1 }) {
                CalendarEventSheetView(sheet: $0)
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 500)
        #endif
    }
}
