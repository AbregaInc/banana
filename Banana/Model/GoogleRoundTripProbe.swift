#if os(macOS)
import Foundation

/// Headless probes against the real Google Calendar API with the real credentials. Each runs from
/// `init`, before any window exists, writes its findings to a file as it goes, and exits — so it
/// can be run on a machine nobody is sitting at, and a hang still leaves evidence.
///
/// A probe launch never reconciles the real calendars as a side effect: `CalendarWriteBack`
/// refuses to sync while any of these arguments is present (`isDiagnosticLaunch`).
///
///  - `--google-roundtrip`: write one private block far in the future, find it by its ownership
///    marker, move it, delete it, confirm it is gone. Self-cleaning.
///  - `--google-window`: READ-ONLY. What Banana would plan with right now — accounts, calendars,
///    whether the read was complete, what counts as meetings/busy/travel — and how many blocks
///    this build owns on each writable calendar.
///  - `--google-repeat`: the event editor's writes, for real, on one private test event far in
///    the future: make it repeat Mon/Wed/Fri, undo that, change the days from an occurrence,
///    rename one occurrence, split the series ("This and following") and undo it, end the series
///    and undo it, and refuse a save over a changed event. Self-cleaning.
///  - `--adopt-legacy-blocks`: DRY RUN. What adopting the blocks written through Apple Calendar
///    would do. Needs Apple Calendar access already granted to this app.
enum GoogleRoundTripProbe {

    static let argument = "--google-roundtrip"
    static let reportPath = "/tmp/banana-google-roundtrip.txt"

    /// This probe's own flags. Other diagnostic launches (previews) also suppress write-back, but
    /// must not start a probe that exits the app.
    static let probeArguments: Set<String> = ["--google-roundtrip", "--google-window",
                                              "--google-dump", "--google-sharing", "--adopt-legacy-blocks", "--google-sync",
                                              "--google-repeat"]

    static var isRequested: Bool {
        !probeArguments.isDisjoint(with: ProcessInfo.processInfo.arguments)
    }

    /// Kick the requested probe off. Returns immediately; the probe exits the process.
    static func runIfRequested() {
        guard isRequested else { return }
        let arguments = ProcessInfo.processInfo.arguments
        Task.detached(priority: .userInitiated) {
            let probe = Probe()
            if arguments.contains("--google-sharing") {
                guard let viewer = ProcessInfo.processInfo.environment["BANANA_CALENDAR_VIEWER"] else {
                    probe.note("BANANA_CALENDAR_VIEWER is required; no requests made.")
                    exit(1)
                }
                if await probe.connect() {
                    for line in await GoogleCalendarService.shared.diagnoseSharing(with: viewer) { probe.note(line) }
                }
            } else if arguments.contains("--google-sync") {
                await probe.sync()
            } else if arguments.contains("--google-dump") {
                await probe.dump()
            } else if arguments.contains("--google-window") {
                await probe.window()
            } else if arguments.contains("--google-repeat") {
                await probe.repeatRoundTrip()
            } else if arguments.contains("--adopt-legacy-blocks") {
                await probe.adoptionDryRun()
            } else {
                await probe.roundTrip()
            }
            let report = probe.text
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
            exit(0)
        }
    }

    private final class Probe: @unchecked Sendable {
        private var lines: [String] = []
        var text: String { lines.joined(separator: "\n") }

        func note(_ line: String) {
            Log.writeBack.notice("[probe] \(line, privacy: .public)")
            lines.append(line)
            // Written as it goes, so a hang still leaves evidence of how far it got.
            PrivateReport.write(text, toPath: GoogleRoundTripProbe.reportPath)
        }

        private var variant: String {
            #if BANANA_BETA
            CalendarWriteBackVariant.beta.markerScheme
            #else
            CalendarWriteBackVariant.production.markerScheme
            #endif
        }

        /// Accounts and calendars, shared by every probe. False when there is nothing to probe.
        func connect() async -> Bool {
            let accounts = GoogleAccountStore.load()
            note("connected accounts: \(accounts.count) — \(accounts.map(\.email).joined(separator: ", "))")
            guard !accounts.isEmpty else { return false }
            let google = await GoogleCalendarService.shared
            _ = await google.adoptAccountsFromStore()
            await google.refresh()
            let broken = await google.accountsNeedingReconnect
            let reasons = await google.reconnectReasons
            for email in broken.sorted() {
                note("NEEDS RECONNECT: \(email) — \(reasons[email] ?? "no reason recorded")")
            }
            let unreadable = await google.accountsWithUnreadableCalendars
            if !unreadable.isEmpty {
                note("CALENDAR LIST UNREADABLE: \(unreadable.sorted().joined(separator: ", "))")
            }
            let all = await google.allCalendarInfos
            note("calendars visible: \(all.count)")
            return true
        }

        /// READ-ONLY. Incremental sync against the real calendars: does each calendar get a sync
        /// token, how long do follow-up reads take, and does the synced copy match a direct read.
        func sync() async {
            note("Google incremental sync")
            note("")
            guard await connect() else { return }
            for line in await GoogleCalendarService.shared.diagnoseSync() { note(line) }
        }

        func roundTrip() async {
            note("Google write-back round trip")
            note("")
            guard await connect() else { return }
            let google = await GoogleCalendarService.shared
            let candidates = await google.writeBackCandidates
            note("writable Google calendars: \(candidates.count) — \(candidates.map { "\($0.titles.first ?? "?") [\($0.accountEmail)]\($0.isOwner ? "" : " shared")" }.joined(separator: "; "))")
            // A named calendar when one is given, so a run can be aimed at a calendar nothing
            // depends on; otherwise the first one the account owns.
            let wanted = ProcessInfo.processInfo.environment["BANANA_PROBE_CALENDAR"]
            guard let target = candidates.first(where: { wanted != nil && $0.titles.contains(wanted!) })
                    ?? candidates.first(where: \.isOwner),
                  let rawID = GoogleCalendarIDs.rawCalendarID(from: target.infoID) else {
                note("no writable Google calendar to test against")
                return
            }
            note("calendar: \(target.titles.first ?? "?") [\(target.accountEmail)]")

            var components = DateComponents()
            components.year = 2027; components.month = 1; components.day = 15
            components.hour = 3; components.minute = 30
            guard let start = Calendar.current.date(from: components) else {
                note("could not build the probe slot")
                return
            }
            let end = start.addingTimeInterval(3600)
            let windowStart = start.addingTimeInterval(-86_400)
            let windowEnd = end.addingTimeInterval(2 * 86_400)
            let itemID = "google-roundtrip-probe"
            var createdID: String?
            var failed = false

            do {
                let eventID = try await google.createBusyBlock(
                    calendarID: rawID, title: "Busy", start: start, end: end,
                    appItemID: itemID, variant: variant)
                createdID = eventID
                note("create: OK")

                // Found by the ownership marker rather than by a remembered id — the property that
                // survives every sync layer, and the thing that makes a block deletable anywhere.
                let afterCreate = try await google.ownedBusyBlocks(
                    calendarID: rawID, variant: variant, from: windowStart, to: windowEnd)
                if afterCreate[itemID] == [eventID] {
                    note("read back by ownership marker: FOUND")
                } else {
                    note("read back by ownership marker: MISSING — a block that can't be found can't be deleted")
                    failed = true
                }

                try await google.updateBusyBlock(
                    calendarID: rawID, eventID: eventID, title: "Busy",
                    start: start.addingTimeInterval(3600), end: end.addingTimeInterval(3600),
                    appItemID: itemID, variant: variant)
                let afterUpdate = try await google.ownedBusyBlocks(
                    calendarID: rawID, variant: variant, from: windowStart, to: windowEnd)
                if afterUpdate[itemID] == [eventID] {
                    note("move: OK, identity kept")
                } else {
                    note("move: LOST IDENTITY")
                    failed = true
                }

                try await google.deleteBusyBlock(calendarID: rawID, eventID: eventID)
                createdID = nil
                let afterDelete = try await google.ownedBusyBlocks(
                    calendarID: rawID, variant: variant, from: windowStart, to: windowEnd)
                if afterDelete[itemID] == nil {
                    note("delete: gone from the server")
                } else {
                    note("delete: STILL THERE — this is the failure that blocks the calendar")
                    failed = true
                }
            } catch {
                note("FAILED: \(error.localizedDescription)")
                failed = true
            }

            // Nothing left behind, whatever happened above.
            if let createdID {
                try? await google.deleteBusyBlock(calendarID: rawID, eventID: createdID)
                note("cleaned up the probe block")
            }
            note(failed ? "RESULT: FAILED" : "RESULT: PASSED — write, find, move and delete all work")
        }

        /// The editor's writes against the real API (`GoogleCalendarService.updateEvent` and its
        /// Undo paths), each checked by reading the occurrences back from Google.
        func repeatRoundTrip() async {
            note("Google repeat round trip")
            note("")
            guard await connect() else { return }
            let google = await GoogleCalendarService.shared
            let candidates = await google.writeBackCandidates
            let wanted = ProcessInfo.processInfo.environment["BANANA_PROBE_CALENDAR"]
            guard let target = candidates.first(where: { wanted != nil && $0.titles.contains(wanted!) })
                    ?? candidates.first(where: \.isOwner),
                  let rawID = GoogleCalendarIDs.rawCalendarID(from: target.infoID) else {
                note("no writable Google calendar to test against")
                return
            }
            note("calendar: \(target.titles.first ?? "?") [\(target.accountEmail)]")

            // Monday 18 January 2027, 03:30: months past every planning horizon (nothing mirrors or
            // plans travel for it), at an hour nothing else is booked.
            let calendar = Calendar.current
            guard let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 18, hour: 3, minute: 30)),
                  let windowEnd = calendar.date(from: DateComponents(year: 2027, month: 2, day: 1)) else {
                note("could not build the probe slot")
                return
            }
            let windowStart = start.addingTimeInterval(-86_400)
            let title = "Banana repeat probe"
            let dayFormat = Date.FormatStyle().weekday(.abbreviated).day()
            var failed = false
            var seriesInfoIDs: [String] = []

            func read() async throws -> [GoogleCalendarService.ProbeOccurrence] {
                try await google.probeOccurrences(calendarID: rawID, query: title, from: windowStart, to: windowEnd)
            }
            func days(_ list: [GoogleCalendarService.ProbeOccurrence]) -> String {
                list.map { $0.start.formatted(dayFormat) }.joined(separator: ", ")
            }
            func expect(_ step: String, _ expectedDays: [Int], titled: [Int: String] = [:]) async throws
                -> [GoogleCalendarService.ProbeOccurrence] {
                let list = try await read()
                let got = list.map { calendar.component(.day, from: $0.start) }
                let titlesOK = titled.allSatisfy { day, name in
                    list.first { calendar.component(.day, from: $0.start) == day }?.title == name
                }
                if got == expectedDays && titlesOK {
                    note("\(step): OK — \(days(list))")
                } else {
                    note("\(step): WRONG — got \(days(list)) [\(list.map(\.title).joined(separator: " | "))], wanted days \(expectedDays)")
                    failed = true
                }
                return list
            }
            func occurrence(on day: Int, in list: [GoogleCalendarService.ProbeOccurrence]) async throws -> GoogleCalendarEvent {
                guard let found = list.first(where: { calendar.component(.day, from: $0.start) == day }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try await google.event(infoID: found.infoID)
            }
            let monWedFri = "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
            let all = [18, 20, 22, 25, 27, 29]

            do {
                let input = CalendarEventInput(title: title, start: start, end: start.addingTimeInterval(1_800),
                                               isAllDay: false, location: nil, notes: "Made and removed by Banana's own check.",
                                               url: nil, availability: .free, alertMinutesBefore: nil)
                let createdID = try await google.createEvent(input, calendarInfoID: target.infoID)
                seriesInfoIDs.append(createdID)
                _ = try await expect("create a single event", [18])

                // 1. Make it repeat: the rule goes on the event itself, which becomes the series.
                let single = try await google.event(infoID: createdID)
                note("access: \(single.access == .full ? "full" : "NOT FULL"), notifies guests: \(single.notifiesGuests)")
                if single.access != .full || single.notifiesGuests { failed = true }
                _ = try await google.updateEvent(single, recurrence: .setRule(monWedFri), fieldsChanged: false)
                _ = try await expect("repeat Mon, Wed, Fri", all)

                // 2. Undo: back to the one event, as it was.
                _ = try await google.updateEvent(single, recurrence: .restore([]), checkUnchanged: false)
                _ = try await expect("undo the repeat", [18])

                // 3. A save over a version that changed since it was opened is refused.
                do {
                    var stale = single
                    stale.title = title + " (stale)"
                    _ = try await google.updateEvent(stale, fieldsChanged: true)
                    note("stale save: WRITTEN — it should have been refused")
                    failed = true
                } catch {
                    note("stale save: refused — \(error.localizedDescription)")
                }

                let fresh = try await google.event(infoID: createdID)
                _ = try await google.updateEvent(fresh, recurrence: .setRule(monWedFri), fieldsChanged: false)
                var list = try await expect("repeat again", all)

                // 4. Change the days from an occurrence: written to the series, then undone.
                let wednesday = try await occurrence(on: 20, in: list)
                let changed = try await google.updateEvent(
                    wednesday, recurrence: .setRule("RRULE:FREQ=WEEKLY;BYDAY=MO,WE"), fieldsChanged: false)
                _ = try await expect("change to Mon, Wed from Wednesday's occurrence", [18, 20, 25, 27])
                try await google.restoreRecurrence(changed)
                list = try await expect("undo the change of days", all)

                // 5. Rename one occurrence only.
                var friday = try await occurrence(on: 22, in: list)
                friday.title = title + " once"
                _ = try await google.updateEvent(friday, scope: .occurrence)
                list = try await expect("rename Friday's occurrence only", all, titled: [22: title + " once", 20: title])

                // 6. This and following, from Monday the 25th: a new series from there, the old one
                //    cut short before it. Then undone.
                var monday = try await occurrence(on: 25, in: list)
                monday.title = title + " B"
                let split = try await google.updateEvent(monday, scope: .thisAndFollowing)
                if let newSeries = split.newSeriesInfoID { seriesInfoIDs.append(newSeries) }
                note("this and following: new series \(split.newSeriesInfoID == nil ? "NOT MADE" : "made")")
                if split.newSeriesInfoID == nil { failed = true }
                _ = try await expect("rename Monday 25th and after", all,
                                     titled: [20: title, 25: title + " B", 29: title + " B"])
                try await google.undoFollowing(split)
                list = try await expect("undo this-and-following", all, titled: [25: title, 29: title])

                // 7. End the series after Wednesday the 20th, then undo.
                let endAt = try await occurrence(on: 20, in: list)
                let ended = try await google.updateEvent(endAt, recurrence: .endAfterOccurrence, fieldsChanged: false)
                _ = try await expect("end the series after Wednesday 20th", [18, 20])
                try await google.restoreRecurrence(ended)
                _ = try await expect("undo ending it", all)
            } catch {
                note("FAILED: \(error.localizedDescription)")
                failed = true
            }

            // Nothing left behind, whatever happened above.
            for id in seriesInfoIDs.reversed() {
                do {
                    try await google.deleteEvent(eventInfoID: id, scope: .series)
                } catch {
                    try? await google.deleteEvent(eventInfoID: id, scope: .occurrence)
                }
            }
            let left = (try? await read()) ?? []
            note(left.isEmpty ? "cleanup: nothing left" : "cleanup: LEFT \(left.count) — \(days(left))")
            if !left.isEmpty {
                failed = true
                for item in left { try? await google.deleteEvent(eventInfoID: item.infoID, scope: .series) }
                let still = (try? await read()) ?? []
                note(still.isEmpty ? "cleanup, second pass: nothing left" : "cleanup, second pass: STILL \(still.count) LEFT")
            }
            note(failed ? "RESULT: FAILED" : "RESULT: PASSED — repeat, undo, change days, rename one, split, end, and refuse a stale save")
        }

        /// Read-only: exactly the read the timeline and write-back make.
        func window() async {
            note("Google calendar window (read-only)")
            note("")
            guard await connect() else { return }
            let google = await GoogleCalendarService.shared
            let smart = await SmartScheduleStore.shared
            let excluded = await smart.settings.excludedCalendarIDs
            let writeExcluded = await smart.settings.writeBackExcludedCalendarIDs
            let shared = await smart.settings.writeBackSharedCalendarIDs
            let infos = await google.allCalendarInfos
            for info in infos {
                note("  \(excluded.contains(info.id) ? "–" : "+") \(info.title) [\(info.sourceTitle)]")
            }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: OccurrenceStore.writeBackTravelHorizonDays, to: start) ?? start
            let fetch = await google.windowFetch(from: start, to: end, excluding: excluded)
            note("read complete: \(fetch.isComplete ? "YES — removals would be allowed" : "NO — write-back would add but never remove")")
            for problem in fetch.problems { note("  problem: \(problem)") }
            for line in await google.diagnoseReads(from: start, to: end) { note(line) }
            note("meetings: \(fetch.window.meetings.count), busy intervals: \(fetch.window.busyIntervals.count) (\(fetch.window.busyIntervals.filter(\.isAppWritten).count) Banana-written), travel events: \(fetch.window.travelEvents.count), synced travel blocks: \(fetch.window.syncedTravelBlocks.count)")

            let candidates = await google.writeBackCandidates
            let destinations = Set(WriteBackDestinations.destinations(
                candidates, excludedIDs: excluded.union(writeExcluded),
                excludedIdentities: [], includedShared: shared))
            note("")
            note("write-back destinations: \(destinations.count) of \(candidates.count) writable")
            let (ownedStart, ownedEnd) = (Date().addingTimeInterval(-7 * 86_400),
                                          Date().addingTimeInterval(Double(OccurrenceStore.writeBackTravelHorizonDays + 14) * 86_400))
            for candidate in candidates {
                guard let raw = GoogleCalendarIDs.rawCalendarID(from: candidate.infoID) else { continue }
                let owned = try? await google.ownedBusyBlocks(calendarID: raw, variant: variant,
                                                              from: ownedStart, to: ownedEnd)
                let copies = owned?.values.reduce(0) { $0 + $1.count }
                let duplicates = owned?.values.filter { $0.count > 1 }.count
                let role = candidate.isOwner ? "own" : "shared"
                note("  \(destinations.contains(candidate.infoID) ? "→" : "·") \(candidate.titles.first ?? "?") [\(candidate.accountEmail), \(role)] — Banana blocks: \(copies.map(String.init) ?? "unreadable")\((duplicates ?? 0) > 0 ? ", \(duplicates!) duplicated" : "")")
            }
            note("")
            note("RESULT: read-only, nothing written")
        }

        /// READ-ONLY. Every event on every calendar over the core window, reduced to what a
        /// coverage check needs — calendar, id, span, busy or free, attendee count, Banana
        /// ownership — to /tmp/banana-google-dump.json. No titles, no descriptions.
        func dump() async {
            note("Google dump (read-only)")
            guard await connect() else { return }
            let google = await GoogleCalendarService.shared
            let read = await google.writableCalendarEvents()
            note("complete: \(read.complete), events: \(read.events.count)")
            let rows: [[String: Any]] = read.events.compactMap { item in
                guard let span = GoogleCalendarDates.range(of: item.event), let id = item.event.id else { return nil }
                let owner = GoogleEventWindowBuilder.ownership(of: item.event)
                return ["cal": item.calendarID, "id": id,
                        "start": span.start.timeIntervalSince1970, "end": span.end.timeIntervalSince1970,
                        "allDay": span.isAllDay, "free": item.event.transparency == "transparent",
                        "attendees": item.event.attendees?.count ?? 0,
                        "declined": item.event.attendees?.first(where: { $0.selfAttendee == true })?.responseStatus == "declined",
                        "item": owner?.appItemID ?? "", "variant": owner?.variant ?? "",
                        "placeholder": CalendarEventTitlePolicy.isPrivacyPlaceholder(item.event.summary),
                        "recurring": item.event.recurringEventId != nil]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows) {
                PrivateReport.write(data, toPath: "/tmp/banana-google-dump.json")
                note("wrote \(rows.count) rows to /tmp/banana-google-dump.json")
            }
        }

        /// Dry run unless `--apply`. `BANANA_LEDGER_PATH` points it at another device's ledger
        /// (copied off that device); otherwise it uses this Mac's own.
        func adoptionDryRun() async {
            let apply = ProcessInfo.processInfo.arguments.contains("--apply")
            let path = ProcessInfo.processInfo.environment["BANANA_LEDGER_PATH"]
            note("Legacy block adoption — \(apply ? "APPLYING (tags ownership only, deletes nothing)" : "DRY RUN, nothing is written")")
            note("ledger: \(path ?? "this Mac's own")")
            note("")
            guard await connect() else { return }
            var foreign: [CalendarWriteBack.LedgerEntry]?
            if let path {
                guard let data = FileManager.default.contents(atPath: path),
                      let entries = try? JSONDecoder().decode([CalendarWriteBack.LedgerEntry].self, from: data) else {
                    note("could not read a ledger at \(path)")
                    return
                }
                foreign = entries
            }
            let writeBack = await CalendarWriteBack.shared
            let report = await writeBack.adoptLegacyBlocks(dryRun: !apply, foreignLedger: foreign)
            note(report.summary)
            for error in report.errors.prefix(10) { note("  error: \(error)") }
            if apply, foreign == nil, report.errors.isEmpty {
                await writeBack.recordAdoptionFinished(report)
                note("this Mac's takeover is recorded as finished; write-back resumes on its next pass")
            }
        }
    }
}
#endif
