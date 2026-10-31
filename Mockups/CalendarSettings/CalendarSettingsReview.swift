import SwiftUI

@main struct CalendarSettingsReviewApp: App {
    var body: some Scene { WindowGroup {
        if ProcessInfo.processInfo.arguments.contains("--filters") { FilterReview() }
        else { CalendarReview() }
    } }
}

struct ReviewCalendar: Identifiable {
    let id = UUID()
    var name: String
    var color: Color
    var shown = true
    var alerts = true
}

struct CalendarReview: View {
    @State private var calendars = [ReviewCalendar(name: "Personal", color: .blue), ReviewCalendar(name: "Work", color: .orange), ReviewCalendar(name: "Training", color: .green), ReviewCalendar(name: "Family", color: .purple, alerts: false), ReviewCalendar(name: "Holidays", color: .red, shown: false, alerts: false)]
    @State private var mode = ProcessInfo.processInfo.arguments.contains("--notifications") ? 1 : 0
    @State private var comparison = ProcessInfo.processInfo.arguments.contains("--quick")
    @State private var showDetail = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Compare quick selection", isOn: $comparison)
                } footer: {
                    Text("Local design review. These sample calendars do not change your account.")
                }
                if comparison {
                    Section {
                        Picker("Control", selection: $mode) {
                            Text("Visibility").tag(0)
                            Text("Notifications").tag(1)
                        }.pickerStyle(.segmented)
                    }
                }
                Section {
                    ForEach($calendars) { $calendar in
                        if comparison {
                            Button {
                                if mode == 0 { calendar.shown.toggle() }
                                else if calendar.shown { calendar.alerts.toggle() }
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(calendar.color).frame(width: 12, height: 12)
                                    Text(calendar.name).foregroundStyle(.primary)
                                    Spacer()
                                    if mode == 0 ? calendar.shown : calendar.shown && calendar.alerts {
                                        Image(systemName: "checkmark").fontWeight(.semibold)
                                    }
                                }.frame(minHeight: 30)
                            }
                            .disabled(mode == 1 && !calendar.shown)
                        } else {
                            NavigationLink {
                                CalendarDetail(calendar: $calendar)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(calendar.color).frame(width: 12, height: 12)
                                    Text(calendar.name)
                                    Spacer()
                                    Text(!calendar.shown ? "Off" : calendar.alerts ? "" : "Alerts off")
                                        .foregroundStyle(.secondary).font(.subheadline)
                                }.frame(minHeight: 30)
                            }
                        }
                    }
                } header: { Text("alex@example.com") }
                footer: {
                    Text(comparison ? (mode == 0 ? "Selected calendars appear in Banana and count toward your availability." : "Choose which calendars can notify you. Calendars that are off cannot send alerts.") : "Choose a calendar to manage its visibility and notifications.")
                }
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                        Text("Synced across your devices").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Calendar visibility")
            .navigationDestination(isPresented: $showDetail) { CalendarDetail(calendar: $calendars[3]) }
            .task { if ProcessInfo.processInfo.arguments.contains("--detail") { showDetail = true } }
        }
        .tint(.blue)
    }
}

struct CalendarDetail: View {
    @Binding var calendar: ReviewCalendar
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Circle().fill(calendar.color).frame(width: 12, height: 12)
                    Text(calendar.name)
                    Spacer()
                    Text("Google").foregroundStyle(.secondary)
                }
            } footer: { Text("alex@example.com") }
            Section {
                Toggle("Show in Banana", isOn: $calendar.shown)
            } footer: {
                Text("Events appear in your plan and count toward your availability.")
            }
            Section {
                Toggle("Allow notifications", isOn: $calendar.alerts)
                    .disabled(!calendar.shown)
            } footer: {
                Text(calendar.shown ? "Turn off to keep seeing these events without invitation alerts or event reminders. Other calendar apps keep their own settings." : "Turn on Show in Banana to receive notifications from this calendar. Your notification preference is kept.")
            }
        }
        .navigationTitle(calendar.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}


// Isolated design prototype. Sample records only; no account access.
struct ReviewFilter: Identifiable {
    let id: String
    let label: String
    var value: String
}

struct FilterReview: View {
    @State private var sentence = "Work meetings next week, excluding declined"
    @State private var filters = [
        ReviewFilter(id: "calendar", label: "Calendar", value: "Work"),
        ReviewFilter(id: "date", label: "Date", value: "Next week"),
        ReviewFilter(id: "type", label: "Type", value: "Meeting"),
        ReviewFilter(id: "status", label: "Status", value: "Not declined")
    ]
    @State private var editing: String?
    @State private var selection = "Next week"
    @State private var dirty = false
        @State private var interpretationError = false
    private var hasMatches: Bool {
        !filters.contains { ($0.id == "date" && $0.value != "Next week") || ($0.id == "calendar" && $0.value != "Work") || ($0.id == "status" && $0.value == "Declined") }
    }
    private let options = ["date": ["Today", "This week", "Next week", "Last week"],
                           "calendar": ["Work", "Personal", "Family"],
                           "type": ["Meeting", "Any event"],
                           "status": ["Not declined", "Accepted", "Declined"]]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.top, 4)
                        TextField("Describe your filters", text: $sentence, axis: .vertical)
                            .lineLimit(2...3)
                            .submitLabel(.search)
                            .onChange(of: sentence) { dirty = true }
                    }
                } footer: {
                    Text(interpretationError ? "This native review supports the displayed example sentence. Restore it to continue, or try the interactive web prototype for more examples." : "Filters and results update as you type.")
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(filters) { filter in
                            HStack(spacing: 0) {
                                Button {
                                    selection = filter.value; editing = filter.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(filter.label).font(.caption).foregroundStyle(.secondary)
                                        Text(filter.value).font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).padding(.leading, 12)
                                }.buttonStyle(.plain)
                                Button {
                                    filters.removeAll { $0.id == filter.id }
                                } label: {
                                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 38, height: 48)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove \(filter.label) filter")
                            }.background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.vertical, 4).disabled(dirty)
                } header: {
                    HStack { Text("Filters"); Spacer(); Text("All must match").textCase(nil) }
                } footer: {
                    Text(dirty ? "Updating filters…" : "Results update automatically. Tap a filter to adjust it.")
                }
                Section {
                    if !interpretationError && hasMatches {
                        event("Product review", detail: "Mon, Oct 26 · 10–11 AM", person: "Alex Chen")
                        event("Team planning", detail: "Tue, Oct 27 · 9–10 AM", person: "Jules Rivera")
                        event("Budget review", detail: "Fri, Oct 30 · 11–11:30 AM", person: "Alex Chen")
                    } else if interpretationError {
                        Text("Update the sentence to see matching events.").foregroundStyle(.secondary)
                    } else {
                        Text("No matching events").foregroundStyle(.secondary)
                    }
                } header: { Text(interpretationError ? "Results" : (hasMatches ? "3 matching events" : "0 matching events")) }
                Section {} footer: { Text("Design preview · Sample data\nOctober 21, 2026 · Plan") }
            }
            .navigationTitle("Filter Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Reset") { filters.removeAll() } }
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("Selection", selection: $selection) {
                                ForEach(options[editing ?? "date"] ?? [], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.inline).labelsHidden()
                                .onChange(of: selection) {
                                    if let index = filters.firstIndex(where: { $0.id == editing }) { filters[index].value = selection }
                                    editing = nil
                                }
                        } footer: {
                            Text(editing == "date" ? "Next week: October 26–November 1. Relative dates follow your calendar settings." : "Choose the value for this filter.")
                        }
                    }
                    .navigationTitle("Edit \(filters.first { $0.id == editing }?.label.lowercased() ?? "filter")")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { editing = nil } }
                    }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .task(id: sentence) {
                guard dirty else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !Task.isCancelled else { return }
                guard sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "work meetings next week, excluding declined" else {
                    interpretationError = true; dirty = false; return
                }
                interpretationError = false
                filters = [ReviewFilter(id: "calendar", label: "Calendar", value: "Work"), ReviewFilter(id: "date", label: "Date", value: "Next week"), ReviewFilter(id: "type", label: "Type", value: "Meeting"), ReviewFilter(id: "status", label: "Status", value: "Not declined")]
                dirty = false
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--filter-edit") { editing = "date" }
            }
        }.tint(.blue)
    }
    private func event(_ title: String, detail: String, person: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text("Work · \(person)").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}
