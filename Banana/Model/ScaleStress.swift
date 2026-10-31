#if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
import Foundation
import SwiftUI
import Darwin

/// Debug-only workload in isolated memory/disk stores. Never enables provider sync, audio or write-back.
@MainActor
final class ScaleStress: ObservableObject {
    static let shared = ScaleStress()
    @Published private(set) var ready = false
    @Published private(set) var calendarFixtureSummary = ""
    static var days: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--stress-days"), args.indices.contains(i + 1),
              let days = Int(args[i + 1]), (1...365).contains(days),
              args.contains("--disable-icloud") else { return nil }
        #if os(macOS)
        guard args.contains("--ui-audit") else { return nil }
        #else
        guard VisualAuditRoute.matches(args) else { return nil }
        #endif
        return days
    }
    // Independent history sizes for native email/calendar acceptance. Absent flags preserve
    // the original component workload and its reviewed baseline exactly.
    static func count(_ flag: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag) else { return fallback }
        guard args.indices.contains(i + 1), let value = Int(args[i + 1]), range.contains(value) else {
            preconditionFailure("Invalid stress count: \(flag)")
        }
        return value
    }
    static var mailDays: Int { count("--stress-mail-days", default: days ?? 1, range: 1...365) }
    static var eventDays: Int { count("--stress-event-days", default: days ?? 1, range: 1...3650) }
    /// Opt-in action coverage; the persistent component fixture keeps its original identities.
    static var calendarActionsEnabled: Bool {
        days != nil && ProcessInfo.processInfo.arguments.contains("--stress-actionable-calendar")
    }

    static var variedCalendar: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--stress-calendar-fixture") else { return false }
        precondition(args.indices.contains(i + 1) && args[i + 1] == "varied-v1",
                     "Unknown supplementary calendar fixture")
        return true
    }

    nonisolated static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "51515151-0000-0000-0000-%012lld", Int64(number)))!
    }
    private var prepared = false

    private static var reportDirectory: URL {
        #if os(macOS)
        AppSupport.directory
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    private static var platform: String {
        #if os(macOS)
        "macOS; disk-paged notes and podcasts; model operations; mail fixture source"
        #elseif targetEnvironment(simulator)
        "iOS Simulator; disk-paged notes and podcasts; model operations; mail fixture source"
        #else
        "iOS physical device; disk-paged notes and podcasts; model operations; mail fixture source"
        #endif
    }

    struct Metric: Codable {
        let name: String
        let medianMS: Double
        let p95MS: Double
        let budgetMS: Double
        let checksum: Int
        // Preserve collection order: the first call and later stalls must remain distinguishable.
        var samplesMS: [Double] = []
        var diagnostics: [SampleDiagnostic]? = nil
        var passed: Bool { p95MS <= budgetMS }
    }
    struct SampleDiagnostic: Codable {
        let startUptime: Double
        let processCPUMS: Double
        let pageFaults: Int64
        let voluntaryContextSwitches: Int64
        let involuntaryContextSwitches: Int64
        let thermalState: Int
    }
    struct Report: Codable {
        let schemaVersion: Int
        let days: Int
        let emails: Int
        let events: Int
        let notes: Int
        let podcasts: Int
        let episodes: Int
        let residentMB: Double
        let metrics: [Metric]
        let passed: Bool
        let platform: String
    }

    func prepare(library: PodcastLibrary, clock: PlaybackClock, smart: SmartScheduleStore) async {
        guard !prepared, let days = Self.days else { return }
        prepared = true
        #if targetEnvironment(simulator)
        if MailRemovalReviewFixture.enabled {
            // This supplementary screen test supplies its own disk-backed mail.
            // Never emit stress measurements for a different workload.
            precondition(!ProcessInfo.processInfo.arguments.contains("--stress-measure") &&
                         !ProcessInfo.processInfo.arguments.contains("--stress-idle-seconds"),
                         "Removal review is a correctness fixture, not the stress workload")
            ready = true
            return
        }
        #endif
        let now = Calendar.current.startOfDay(for: Date())
        var metrics: [Metric] = []
        func measure(_ name: String, budget: Double, _ action: () -> Int) {
            var times: [Double] = []
            let diagnose = ProcessInfo.processInfo.arguments.contains("--stress-diagnostics")
            var diagnostics: [SampleDiagnostic] = []
            var checksum = 0
            for _ in 0..<7 {
                var before = rusage()
                if diagnose { getrusage(RUSAGE_SELF, &before) }
                let start = ProcessInfo.processInfo.systemUptime
                checksum &+= action()
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                if diagnose {
                    var after = rusage()
                    getrusage(RUSAGE_SELF, &after)
                    func cpuMS(_ usage: rusage) -> Double {
                        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
                    }
                    diagnostics.append(SampleDiagnostic(startUptime: start,
                        processCPUMS: cpuMS(after) - cpuMS(before),
                        pageFaults: Int64(after.ru_majflt - before.ru_majflt),
                        voluntaryContextSwitches: Int64(after.ru_nvcsw - before.ru_nvcsw),
                        involuntaryContextSwitches: Int64(after.ru_nivcsw - before.ru_nivcsw),
                        thermalState: ProcessInfo.processInfo.thermalState.rawValue))
                }
            }
            let ordered = times
            times.sort()
            metrics.append(Metric(name: name, medianMS: times[3], p95MS: times[6],
                                  budgetMS: budget, checksum: checksum, samplesMS: ordered,
                                  diagnostics: diagnose ? diagnostics : nil))
        }
        let noteCount = Self.count("--stress-notes", default: days * 1_000, range: 0...365_000)
        let showCount = Self.count("--stress-podcasts", default: days * 10, range: 0...3_650)
        let episodesPerShow = Self.count("--stress-episodes-per-show", default: 1_000, range: 1...10_000)
        let notes = (0..<noteCount).map { i in
            VoiceNote(id: Self.id(i), createdAt: now.addingTimeInterval(-Double(i) * 60),
                      archivedAt: i.isMultiple(of: 5) ? now : nil, audioFilename: "",
                      transcript: "Stress note \(i): \(i.isMultiple(of: 17) ? "needle" : "ordinary") project planning and follow-up.",
                      status: .transcribed)
        }
        VoiceNoteStore.shared.injectStress(notes)
        await library.whenLoaded()
        let catalogURL = AppSupport.directory.appendingPathComponent("podcast-catalog.sqlite")
        let shows: [Podcast]
        do {
            shows = try await Task.detached(priority: .userInitiated) {
                let catalog = try PodcastCatalog.open(at: catalogURL)
                var result: [Podcast] = []
                for show in 0..<showCount {
                    let podcast = Podcast(
                        id: Self.id(show), feedURL: URL(string: "https://stress.invalid/feed/\(show)")!,
                        title: "Stress podcast \(show)", episodes: (0..<episodesPerShow).map { episode in
                            Episode(id: "stress-\(show)-\(episode)", title: "Episode \(episode)",
                                    audioURL: URL(string: "https://stress.invalid/audio/\(show)/\(episode)")!,
                                    pubDate: now.addingTimeInterval(-Double((episode * 7919) % 1000) * 3600),
                                    duration: 1800, summary: "A deterministic episode about project planning.")
                        })
                    result.append(try catalog.stage(podcast))
                }
                return try catalog.save(result)
            }.value
        } catch { fatalError("Stress disk catalog: \(error)") }
        library.injectStress(shows)
        precondition(VoiceNoteStore.shared.noteCount == noteCount)
        precondition(shows.reduce(0) { $0 + $1.episodeCount } == showCount * episodesPerShow)
        let meetings: [MeetingInfo]
        if Self.variedCalendar {
            let density = Self.count("--stress-events-per-day", default: 100, range: 1...1000)
            let fixture = FixtureStore(CalendarFixtureConfiguration(args: ["--fixture", "varied-v1", "--days", String(Self.eventDays),
                "--density", String(density), "--seed", "20261009"]), anchor: now, leadingDays: 0)
            let palette = ["#1A66D9", "#BF3340", "#26994D", "#8C40BF", "#D9731A", "#1A99A6",
                           "#B3408C", "#738026", "#4D59BF", "#A66633", "#338C73", "#8C5973"]
            let rawIDs = (0..<12).map { "stress-\($0).invalid" }
            let infoIDs = rawIDs.map(GoogleCalendarIDs.calendarInfoID)
            smart.injectPreviewCalendarColors(Dictionary(uniqueKeysWithValues: zip(infoIDs, palette)))
            meetings = fixture.byDay.keys.sorted().flatMap { fixture.byDay[$0]! }.map { event in
                MeetingInfo(start: event.start, end: event.end, coordinate: nil, address: nil,
                    isVirtual: true, title: String(event.title!.dropFirst(FixtureCalendar.names[event.calendarIndex].count + 2)),
                    eventID: Self.calendarActionsEnabled
                        ? GoogleCalendarIDs.eventInfoID(calendarID: rawIDs[event.calendarIndex], eventID: "varied-\(event.id)")
                        : "varied-\(event.id)", calendarID: infoIDs[event.calendarIndex])
            }
            var summary = fixture.fixtureSummary
            summary["anchor"] = now.timeIntervalSince1970
            summary["installedCalendarColors"] = Dictionary(uniqueKeysWithValues: zip(infoIDs, palette))
            summary["installedCalendarCounts"] = Dictionary(grouping: meetings, by: { $0.calendarID! }).mapValues(\.count)
            var installedDigest = FixtureDigest()
            for meeting in meetings {
                installedDigest.add("\(meeting.title)/\(meeting.start.timeIntervalSince1970)/\(meeting.end!.timeIntervalSince1970)/\(meeting.calendarID!)")
            }
            summary["installedContentChecksum"] = String(installedDigest.value, radix: 16)
            summary["scope"] = "Supplementary full-app timed events; legacy component fixture unchanged; no provider sync/recurrence expansion"
            let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            calendarFixtureSummary = String(decoding: data, as: UTF8.self)
            try! data.write(to: Self.reportDirectory.appendingPathComponent("scale-calendar-fixture.json"), options: .atomic)
        } else {
            precondition(!ProcessInfo.processInfo.arguments.contains("--stress-events-per-day"),
                         "Density overrides require the supplementary varied-v1 fixture")
            meetings = (0..<(Self.eventDays * 100)).map { i in
                let start = now.addingTimeInterval(Double(i / 100) * 86400 + Double(i % 100) * 600)
                return MeetingInfo(start: start, end: start.addingTimeInterval(i.isMultiple(of: 10) ? 86400 : 1800),
                                   coordinate: nil, address: nil, isVirtual: true,
                                   title: "Stress event \(i)", eventID: Self.calendarActionsEnabled
                                    ? GoogleCalendarIDs.eventInfoID(calendarID: "stress.invalid", eventID: "stress-event-\(i)")
                                    : "stress-event-\(i)")
            }
        }
        OccurrenceStore.shared.injectStress(meetings)
        guard let mail = MailSession.shared?.source as? MailFixtureSource else {
            fatalError("Stress route requires the fixture mail source")
        }
        // Every section is loaded together, even when only one tab is visible.
        if ProcessInfo.processInfo.arguments.contains("--stress-measure") {
            measure("mail.firstPage", budget: 50) {
                mail.cachedFirstPage(MailScope(place: .mailbox(.inbox)))!.rows.count
            }
            let target = MailConversationID(account: MailFixtureConversations.account, thread: "stress-0")
            var read = false
            measure("mail.readMutation", budget: 100) {
                read.toggle()
                _ = mail.apply(.read(read), to: .conversations([target]))
                return mail.cachedFirstPage(MailScope(place: .mailbox(.inbox)))!.rows.count
            }
            measure("calendar.visibleWeek", budget: 16) {
                OccurrenceStore.shared.planningWindow(from: now, to: now.addingTimeInterval(7 * 86400)).count
            }
            measure("calendar.day", budget: 8) {
                OccurrenceStore.shared.occurrences(on: now).count
            }
            measure("notes.search", budget: 100) {
                VoiceNoteStore.shared.matchingNotes(search: "needle", archived: false).count
            }
            measure("notes.browse", budget: 16) {
                VoiceNoteStore.shared.matchingNotes(search: "", archived: false).count
            }
            measure("podcasts.nextAcrossCatalog", budget: 100) {
                library.podcasts.reduce(0) { $0 + ($1.nextEpisode() == nil ? 0 : 1) }
            }
            measure("podcasts.downloadCandidates", budget: 100) {
                library.podcasts.reduce(0) { $0 + $1.nextUnplayed(3).count }
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let report = Report(schemaVersion: 1, days: days, emails: Self.mailDays * 2_000,
                                events: meetings.count, notes: notes.count, podcasts: shows.count,
                                episodes: shows.count * episodesPerShow, residentMB: Double(usage.ru_maxrss) / 1_048_576,
                                metrics: metrics, passed: metrics.allSatisfy(\.passed),
                                platform: Self.platform)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = Self.reportDirectory.appendingPathComponent("scale-stress.json")
                try encoder.encode(report).write(to: url, options: .atomic)
                print("SCALE_STRESS_RESULT \(url.path)")
            } catch { assertionFailure("Stress report: \(error)") }
        }
        print("SCALE_STRESS_READY \(AppSupport.directory.path)")
        ready = true
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--stress-idle-seconds"), arguments.indices.contains(flag + 1),
           let seconds = Int(arguments[flag + 1]), (1...60).contains(seconds) {
            // Exclude initial layout/paging, then inject a 10 Hz playhead without playing audio.
            // The large list roots should not observe this high-frequency publisher at all.
            try? await Task.sleep(for: .seconds(5))
            let before = RenderStats.lifetimeSnapshot()
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<(seconds * 10) {
                clock.time += 0.1
                try? await Task.sleep(for: .milliseconds(100))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let counts = RenderStats.lifetimeSnapshot().mapValues { $0 }
            let rates = counts.mapValues { Double($0) }
                .map { key, value in (key, (value - Double(before[key, default: 0])) / elapsed) }
            let watched = Set(["RootView", "PlannerTab", "WeekView", "TodayView", "NotesView", "PodcastsView", "PodcastDetailView", "MailSection"])
            let expectedRoot = arguments.contains("--library") ? "PodcastsView"
                : arguments.contains("--plan") ? "PlannerTab"
                : arguments.contains("--mail") ? "MailSection" : "NotesView"
            let observedRoot = counts[expectedRoot, default: 0] > 0
            let storms = rates.filter { watched.contains($0.0) && $0.1 > 2 }
            var report: [String: Any] = ["seconds": elapsed, "clockTicks": seconds * 10,
                "rendersPerSecond": Dictionary(uniqueKeysWithValues: rates),
                "budgetRendersPerSecond": 2, "observedRoot": observedRoot, "passed": storms.isEmpty && observedRoot]
            if arguments.contains("--calendar-artwork-profile") {
                let preparation = CalendarArtworkPreparation.shared
                var artwork = preparation.cache.preparationReport()
                artwork["consumerPixelBytes"] = preparation.consumers.retainedBytes
                artwork["consumerPixelLimit"] = preparation.consumers.limit
                artwork["pendingJobs"] = preparation.pendingCount
                artwork["queueRejections"] = preparation.queueRejections
                artwork["queueAdmissionDeferrals"] = preparation.queueAdmissionDeferrals
                artwork["queueRejectedTitles"] = preparation.queueRejectedTitles
                artwork["preparedPolicyEnabled"] = CalendarPreparedArtwork.enabled
                report["calendarArtwork"] = artwork
            }
            let url = Self.reportDirectory.appendingPathComponent("scale-idle.json")
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
            catch { assertionFailure("Stress idle report: \(error)") }
        }
    }
}

struct ScaleStressBadge: View {
    @ObservedObject private var stress = ScaleStress.shared
    var body: some View {
        if ScaleStress.days != nil {
            Text(stress.ready ? "Stress ready" : "Loading stress data")
                .font(.caption2).padding(3).background(.regularMaterial)
                .accessibilityIdentifier(stress.ready ? "stress.ready" : "stress.loading")
                .accessibilityValue(stress.calendarFixtureSummary)
                .allowsHitTesting(false)
        }
    }
}
#endif
