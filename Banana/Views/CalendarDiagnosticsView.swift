import SwiftUI

/// A read-only view of the calendar inputs that feed Banana's timeline: which Google accounts are
/// connected and readable, which calendars they list, and whether the last read was complete —
/// the thing that decides whether write-back is allowed to remove anything.
struct CalendarDiagnosticsView: View {
    private struct Snapshot {
        var eventCount = 0
        var isComplete = true
        var problems: [String] = []
        var reconciliationReport = ""
    }

    @EnvironmentObject private var smart: SmartScheduleStore
    @ObservedObject private var writeBack = CalendarWriteBack.shared
    @StateObject private var google = GoogleCalendarService.shared
    @State private var snapshot = Snapshot()
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section("Google accounts") {
                if google.accounts.isEmpty {
                    Text("No Google account is connected. Connect one in Settings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(google.accounts) { account in
                    let broken = google.accountsToSignInAgain.contains(account.id)
                        || google.accountsWithUnreadableCalendars.contains(account.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Label(account.email, systemImage: broken ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(broken ? .orange : .primary)
                        if let reason = google.reconnectReasons[account.id] {
                            Text("Google said: \(reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if google.accountsNeedingServiceSignIn.contains(account.id) {
                            Text("The Banana service needs a sign-in for it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if google.accountsWithUnreadableCalendars.contains(account.id) {
                            Text("Its calendar list could not be loaded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Last read, next 7 days") {
                LabeledContent("Timeline events") { Text("\(snapshot.eventCount)") }
                LabeledContent("Every calendar read") {
                    Text(snapshot.isComplete ? "Yes" : "No — busy blocks are added but never removed")
                        .foregroundStyle(snapshot.isComplete ? .green : .orange)
                }
                ForEach(snapshot.problems, id: \.self) { problem in
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            Section("Calendars") {
                ForEach(google.allCalendarInfos) { calendar in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        let writable = writeBack.writableCalendars.contains { $0.id == calendar.id }
                        Image(systemName: writable ? "checkmark.circle.fill" : "eye")
                            .foregroundStyle(writable ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.title)
                            Text(calendar.sourceTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if smart.settings.excludedCalendarIDs.contains(calendar.id) {
                            Text("Excluded")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(DS.Palette.accent)
                        }
                    }
                }
            }

            if !snapshot.reconciliationReport.isEmpty {
                Section {
                    ShareLink(item: snapshot.reconciliationReport) {
                        Label("Share calendar troubleshooting report", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Includes event times and calendar permissions, with anonymous labels for matching copies. Event titles, email addresses, notes and locations are omitted. Nothing is sent until you share it.")
                }
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(isRefreshing ? "Refreshing…" : "Refresh calendar diagnostics", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            } footer: {
                Text("Excluded calendars are left off Banana’s timeline on purpose. A calendar can be readable without being writable; its events still appear.")
            }
        }
        .navigationTitle("Calendar diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await google.refresh()
        writeBack.refreshCalendars()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        let fetch = await google.windowFetch(from: start, to: end,
                                             excluding: smart.settings.excludedCalendarIDs)
        snapshot = Snapshot(eventCount: fetch.window.meetings.count,
                            isComplete: fetch.isComplete,
                            problems: fetch.problems,
                            reconciliationReport: google.calendarReconciliationReport(from: start, to: end,
                                excluding: smart.settings.excludedCalendarIDs))
        await smart.refreshCalendarAuthorization()
    }
}
