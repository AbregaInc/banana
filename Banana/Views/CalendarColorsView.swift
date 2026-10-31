import SwiftUI

/// Settings › Accounts & calendars › Calendar colours: the colour each calendar is shown in, and
/// choosing another (`CalendarColorAssignment`). Automatic is Google's colour unless another
/// calendar already has it. Banana-only: Google keeps its own.
struct CalendarColorsView: View {
    @EnvironmentObject private var smart: SmartScheduleStore

    private var byAccount: [(account: String, calendars: [CalendarSourceInfo])] {
        let grouped = Dictionary(grouping: smart.availableCalendars, by: \.sourceTitle)
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            ForEach(byAccount, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.calendars) { row($0) }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Every calendar gets its own colour: Google\u{2019}s, unless another calendar already looks like it \u{2014} Google picks colours per account, so two accounts often share one. Choose any here; Google Calendar keeps its own.")
            }
        }
        .settingsFormStyle()
        .navigationTitle("Calendar colours")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ calendar: CalendarSourceInfo) -> some View {
        let shown = smart.shownColor(calendar.id, google: calendar.colorHex)
        let chosen = smart.settings.calendarColorChoices[calendar.id]
        return Menu {
            Picker("Colour", selection: Binding<String?>(
                get: { smart.settings.calendarColorChoices[calendar.id] },
                set: { smart.settings.calendarColorChoices[calendar.id] = $0 })) {
                Label("Automatic", systemImage: "wand.and.stars").tag(String?.none)
                Divider()
                ForEach(CalendarColorAssignment.palette, id: \.self) { hex in
                    Label {
                        Text(Self.name(hex))
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(calendarTint(hex))
                    }
                    .tag(String?.some(hex))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Space.m) {
                Circle().fill(calendarTint(shown)).frame(width: 14, height: 14)
                Text(calendar.title).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text(chosen == nil ? "Automatic" : Self.name(chosen!))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("calendarColor.\(calendar.id)")
    }

    static func name(_ hex: String) -> String {
        CalendarColorAssignment.name(hex) ?? hex
    }
}
