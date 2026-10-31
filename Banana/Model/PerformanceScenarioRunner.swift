#if PERFORMANCE_TESTING && os(iOS)
import AVFoundation
import Darwin
import Foundation
import SwiftUI
import UIKit

enum PerformanceScenarioRunnerError: LocalizedError {
    case fixtureMissing
    case fixtureDurationInvalid
    case fixtureTooShort(episodeCount: Int)
    case playbackDidNotStart
    case playbackStopped
    case playbackWasNotLocal
    case readinessTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .fixtureMissing:
            return "No audio fixture exists in Documents/PerformanceFixtures."
        case .fixtureDurationInvalid:
            return "The audio fixture has no finite, positive duration."
        case .fixtureTooShort(let episodeCount):
            return "The fixture would require \(episodeCount) synthetic episodes; use a longer source."
        case .playbackDidNotStart:
            return "AVPlayer did not enter the playing state within 15 seconds."
        case .playbackStopped:
            return "AVPlayer stopped during the measurement window."
        case .playbackWasNotLocal:
            return "The production player did not resolve the fixture through its local download path."
        case .readinessTimedOut(let blockers):
            return "The device did not become ready within 15 minutes: \(blockers)."
        }
    }
}

/// Minimal screen used only by Release+PERFORMANCE_TESTING builds. It keeps the normal production
/// service graph and playback implementation, but removes unrelated foreground rendering from a
/// locked-phone playback measurement. Scene transitions still drive the same visibility/player
/// cadence that RootView uses in the shipping app.
struct PerformanceScenarioView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var player: PlayerController
    @State private var phaseMessage: String?

    private var defaultMessage: String {
        switch PerformanceScenarioRunner.requestedScenarioID {
        case "playback.local":
            return "Playback starts before the settling window. Disconnect USB, then lock the phone."
        case "planner.refresh":
            return "Disconnect USB and keep the phone unlocked while it settles. This run is silent."
        case "planner.dense":
            return "Building a deterministic dense planner fixture. This run is silent."
        case "artwork.decode":
            return "Decoding deterministic podcast artwork. This run is silent."
        default:
            return "Silent idle control. No audio, alarms, or notifications are started by this run."
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Performance run")
                    .font(.headline)
                Text(phaseMessage ?? defaultMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .foregroundStyle(.white)
        }
        .onAppear {
            AppVisibility.shared.set(active: true)
            player.setInterfaceActive(true)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppVisibility.shared.set(active: true)
                player.setInterfaceActive(true)
            case .background:
                AppVisibility.shared.set(active: false)
                player.setInterfaceActive(false)
                player.commitProgress()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .performanceScenarioPhase)) {
            phaseMessage = $0.object as? String
        }
    }
}

private extension Notification.Name {
    static let performanceScenarioPhase = Notification.Name("BananaPerformanceScenarioPhase")
}

@MainActor
enum PerformanceScenarioRunner {
    static var requestedScenarioID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--perf-scenario"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--perf-scenario")
    }

    static func runRequested(
        library: PodcastLibrary,
        player: PlayerController,
        downloads: DownloadManager,
        smart: SmartScheduleStore,
        routines: RoutineStore,
        health: HealthKitStore,
        occurrences: OccurrenceStore
    ) async {
        let request: PerformanceScenarioRequest
        do {
            guard let parsed = try PerformanceScenarioRequest.parse(
                arguments: ProcessInfo.processInfo.arguments)
            else { return }
            request = parsed
        } catch {
            fputs("PERF_RUN_ARGUMENT_ERROR \(error)\n", stderr)
            return
        }

        var startupMilliseconds: Double?
        do {
            if request.scenarioID == "planner.refresh"
                || request.scenarioID == "planner.dense"
                || request.scenarioID == "artwork.decode" {
                UIApplication.shared.isIdleTimerDisabled = true
                publishPhase(
                    request.scenarioID == "planner.dense"
                        ? "Building the deterministic dense planner fixture. No personal data or audio is used."
                        : request.scenarioID == "artwork.decode"
                        ? "Decoding the deterministic artwork fixture. No network or audio is used."
                        : request.isTetheredMeasurement
                        ? "Tethered planner run is settling. Keep the phone connected; no audio will play."
                        : "Disconnect USB and keep the phone unlocked while the device settles. No audio will play."
                )
            }
            if request.scenarioID == "playback.local" {
                startupMilliseconds = try await prepareLocalPlayback(
                    request: request,
                    library: library,
                    player: player,
                    downloads: downloads)
            }
            if request.settleSeconds > 0 {
                try await Task.sleep(for: .seconds(request.settleSeconds))
            }
            if request.scenarioID == "planner.refresh" {
                try await waitForPlannerReadiness(request: request)
            }
            try await measure(
                request: request,
                player: player,
                startupMilliseconds: startupMilliseconds,
                smart: smart,
                routines: routines,
                health: health,
                occurrences: occurrences)
        } catch {
            UIApplication.shared.isIdleTimerDisabled = false
            if player.hasCurrent {
                player.stop(reason: "performance harness failure")
            }
            writePreparationFailure(request: request, error: error)
            publishPhase("Run did not start: \(error.localizedDescription)")
        }
    }

    private static func waitForPlannerReadiness(
        request: PerformanceScenarioRequest
    ) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        let deadline = monotonicNanoseconds() + 15 * 60 * 1_000_000_000
        var blockers: [String] = []
        repeat {
            let current = conditions()
            blockers = []
            if !request.isTetheredMeasurement && current.thermalState != "nominal" {
                blockers.append("thermal is \(current.thermalState)")
            }
            if current.lowPowerMode {
                blockers.append("Low Power Mode is on")
            }
            if !request.isTetheredMeasurement {
                if current.batteryState != "unplugged" {
                    blockers.append("USB/power is still connected")
                }
                if current.network != "offline" {
                    blockers.append("Airplane Mode is off")
                }
            }
            if blockers.isEmpty { return }
            publishPhase("Waiting to start: \(blockers.joined(separator: " · "))")
            try await Task.sleep(for: .seconds(5))
        } while monotonicNanoseconds() < deadline
        throw PerformanceScenarioRunnerError.readinessTimedOut(blockers.joined(separator: ", "))
        #endif
    }

    private static func prepareLocalPlayback(
        request: PerformanceScenarioRequest,
        library: PodcastLibrary,
        player: PlayerController,
        downloads: DownloadManager
    ) async throws -> Double {
        let fixture = try fixtureURL()
        let assetDuration = try await AVURLAsset(url: fixture).load(.duration).seconds
        guard assetDuration.isFinite, assetDuration > 0 else {
            throw PerformanceScenarioRunnerError.fixtureDurationInvalid
        }
        let requiredPlayback = request.durationSeconds + request.settleSeconds + 30
        let episodeCount = max(2, Int(ceil(requiredPlayback / assetDuration)) + 1)
        guard episodeCount <= 64 else {
            throw PerformanceScenarioRunnerError.fixtureTooShort(episodeCount: episodeCount)
        }

        let episodeIDs = (0..<episodeCount).map { "performance-\(request.runID)-\($0)" }
        let localURL = try downloads.performanceRegisterDownloads(
            episodeIDs: episodeIDs,
            fixture: fixture)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let episodes = episodeIDs.enumerated().map { index, id in
            Episode(
                id: id,
                title: "Performance fixture \(index + 1)",
                audioURL: localURL,
                pubDate: baseDate.addingTimeInterval(Double(index)),
                duration: assetDuration)
        }
        let podcast = Podcast(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            feedURL: URL(string: "https://performance.invalid/feed.xml")!,
            title: "Performance Fixture",
            direction: .oldestFirst,
            speed: 1,
            downloadRule: .off,
            syncToWatch: false,
            episodes: episodes)
        library.installPerformanceFixture([podcast])

        let started = monotonicNanoseconds()
        player.play(episodes[0], in: podcast, autoSleepEligible: false)
        let deadline = started + 15_000_000_000
        while !player.performanceIsActuallyPlaying && monotonicNanoseconds() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard player.performanceIsActuallyPlaying else {
            throw PerformanceScenarioRunnerError.playbackDidNotStart
        }
        guard player.performanceSourceIsLocal else {
            throw PerformanceScenarioRunnerError.playbackWasNotLocal
        }
        return Double(monotonicNanoseconds() - started) / 1_000_000
    }

    private static func measure(
        request: PerformanceScenarioRequest,
        player: PlayerController,
        startupMilliseconds: Double?,
        smart: SmartScheduleStore,
        routines: RoutineStore,
        health: HealthKitStore,
        occurrences: OccurrenceStore
    ) async throws {
        let startWall = Date()
        let startMonotonic = monotonicNanoseconds()
        let initialConditions = conditions()
        let initialSnapshot = ProcessSnapshot.capture()
        let initialStallCount = player.performancePlaybackStallCount
        var maximumFootprint = initialSnapshot.footprintMB
        let manifest = PerformanceRunManifest(
            runID: request.runID,
            scenarioID: request.scenarioID,
            variant: request.variant,
            fixtureDigest: request.fixtureDigest,
            startedAt: startWall,
            monotonicStartNanoseconds: startMonotonic,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            gitCommit: request.gitCommit,
            configuration: "Release+PERFORMANCE_TESTING",
            device: device(),
            initialConditions: initialConditions)
        let recorder = try PerformanceRunRecorder(
            directory: runDirectory(runID: request.runID),
            manifest: manifest)
        try recorder.emit(
            .scenarioStarted,
            values: startupMilliseconds.map { ["startupMilliseconds": $0] },
            wallTime: startWall,
            monotonicNanoseconds: startMonotonic)
        var workloadMeasurements: [String: Double] = [:]
        if request.scenarioID == "planner.refresh" {
            publishPhase("Reading Calendar and Reminders, then building the real planner timeline…")
            let workloadStartWall = Date()
            let workloadStartMonotonic = monotonicNanoseconds()
            let workloadStartSnapshot = ProcessSnapshot.capture()
            try recorder.emit(
                .phaseStarted,
                phase: "plannerRefresh",
                wallTime: workloadStartWall,
                monotonicNanoseconds: workloadStartMonotonic)

            // Reproduce the planner's real read/materialization graph, but never mutate the
            // person's calendars/reminders or schedule alarms from a performance experiment.
            smart.health = health
            occurrences.routines = routines
            occurrences.smart = smart
            occurrences.alarms = nil
            occurrences.health = health
            await smart.refreshAgenda()
            await occurrences.recomputeReadOnlyForPerformance()

            let workloadEndWall = Date()
            let workloadEndMonotonic = monotonicNanoseconds()
            let workloadEndSnapshot = ProcessSnapshot.capture()
            workloadMeasurements = workloadEndSnapshot.values(since: workloadStartSnapshot)
                .reduce(into: [:]) { result, item in
                    result["plannerRefresh.\(item.key)"] = item.value
                }
            workloadMeasurements["plannerRefresh.durationMilliseconds"] =
                Double(workloadEndMonotonic - workloadStartMonotonic) / 1_000_000
            workloadMeasurements["plannerRefresh.agendaEventCount"] =
                Double(smart.todayMeetings.count + smart.tomorrowMeetings.count)
            workloadMeasurements["plannerRefresh.occurrenceCount"] =
                Double(occurrences.occurrences.count)
            workloadMeasurements["plannerRefresh.reminderCount"] =
                Double(occurrences.occurrences.lazy.filter { $0.reminderID != nil }.count)
            try recorder.emit(
                .phaseFinished,
                phase: "plannerRefresh",
                values: workloadMeasurements,
                wallTime: workloadEndWall,
                monotonicNanoseconds: workloadEndMonotonic)

            if !request.isTetheredMeasurement {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            publishPhase("Planner refresh complete. Lock the phone now. No audio will play.")
        } else if request.scenarioID == "planner.dense" {
            publishPhase("Materializing the deterministic 14-day planner fixture…")
            let workloadStartWall = Date()
            let workloadStartMonotonic = monotonicNanoseconds()
            let workloadStartSnapshot = ProcessSnapshot.capture()
            try recorder.emit(
                .phaseStarted,
                phase: "densePlannerMaterialization",
                wallTime: workloadStartWall,
                monotonicNanoseconds: workloadStartMonotonic)

            let fixture = try densePlannerFixture()

            let workloadEndWall = Date()
            let workloadEndMonotonic = monotonicNanoseconds()
            let workloadEndSnapshot = ProcessSnapshot.capture()
            workloadMeasurements = workloadEndSnapshot.values(since: workloadStartSnapshot)
                .reduce(into: [:]) { result, item in
                    result["densePlanner.\(item.key)"] = item.value
                }
            workloadMeasurements["densePlanner.durationMilliseconds"] =
                Double(workloadEndMonotonic - workloadStartMonotonic) / 1_000_000
            workloadMeasurements["densePlanner.meetingCount"] = Double(fixture.meetingCount)
            workloadMeasurements["densePlanner.taskSourceCount"] = Double(fixture.taskSourceCount)
            workloadMeasurements["densePlanner.occurrenceCount"] =
                Double(fixture.occurrenceCount)
            workloadMeasurements["densePlanner.encodedBytes"] = Double(fixture.encodedBytes)
            try recorder.emit(
                .phaseFinished,
                phase: "densePlannerMaterialization",
                values: workloadMeasurements,
                wallTime: workloadEndWall,
                monotonicNanoseconds: workloadEndMonotonic)
            publishPhase("Dense planner materialization complete. No personal data was read.")
        } else if request.scenarioID == "artwork.decode" {
            let data = makeArtworkFixture()
            let maxPixel: CGFloat = request.variant.contains("targeted") ? 256 : 1000
            let decodeCount = 60
            publishPhase("Decoding \(decodeCount) list artworks at \(Int(maxPixel)) px…")
            let workloadStartWall = Date()
            let workloadStartMonotonic = monotonicNanoseconds()
            let workloadStartSnapshot = ProcessSnapshot.capture()
            try recorder.emit(
                .phaseStarted,
                phase: "artworkDecode",
                wallTime: workloadStartWall,
                monotonicNanoseconds: workloadStartMonotonic)

            let decodedPixels = ImageCache.shared.performanceDecode(
                data: data,
                maxPixel: maxPixel,
                count: decodeCount)

            let workloadEndWall = Date()
            let workloadEndMonotonic = monotonicNanoseconds()
            let workloadEndSnapshot = ProcessSnapshot.capture()
            workloadMeasurements = workloadEndSnapshot.values(since: workloadStartSnapshot)
                .reduce(into: [:]) { result, item in
                    result["artworkDecode.\(item.key)"] = item.value
                }
            workloadMeasurements["artworkDecode.durationMilliseconds"] =
                Double(workloadEndMonotonic - workloadStartMonotonic) / 1_000_000
            workloadMeasurements["artworkDecode.sourceBytes"] = Double(data.count)
            workloadMeasurements["artworkDecode.imageCount"] = Double(decodeCount)
            workloadMeasurements["artworkDecode.maxPixel"] = Double(maxPixel)
            workloadMeasurements["artworkDecode.decodedPixels"] = Double(decodedPixels)
            workloadMeasurements["artworkDecode.decodedRGBABytes"] =
                Double(decodedPixels * 4)
            try recorder.emit(
                .phaseFinished,
                phase: "artworkDecode",
                values: workloadMeasurements,
                wallTime: workloadEndWall,
                monotonicNanoseconds: workloadEndMonotonic)
            publishPhase("Artwork decode complete. No network or audio was used.")
        }

        let phase: String
        switch request.scenarioID {
        case "playback.local": phase = "steadyPlayback"
        case "planner.refresh": phase = "lockedStandby"
        case "planner.dense": phase = "densePlannerIdle"
        case "artwork.decode": phase = "artworkIdle"
        default: phase = "idle"
        }
        let measurementStartMonotonic = monotonicNanoseconds()
        try recorder.emit(
            .phaseStarted,
            phase: phase,
            wallTime: Date(),
            monotonicNanoseconds: measurementStartMonotonic)
        let deadline = measurementStartMonotonic
            + UInt64(request.durationSeconds * 1_000_000_000)
        var playbackStopped = false
        repeat {
            let now = monotonicNanoseconds()
            if now >= deadline { break }
            let remaining = Double(deadline - now) / 1_000_000_000
            try await Task.sleep(
                for: .seconds(min(request.sampleIntervalSeconds, remaining)))
            let sampleTime = monotonicNanoseconds()
            let snapshot = ProcessSnapshot.capture()
            maximumFootprint = max(maximumFootprint, snapshot.footprintMB)
            if request.scenarioID == "playback.local"
                && (!player.performanceIsActuallyPlaying || !player.performanceSourceIsLocal) {
                playbackStopped = true
            }
            try recorder.emit(
                .sample,
                phase: phase,
                values: snapshot.values(since: initialSnapshot)
                    .merging([
                        "elapsedSeconds": Double(sampleTime - measurementStartMonotonic) / 1_000_000_000,
                        "batteryLevel": batteryLevelForMeasurement(),
                        "playbackActuallyPlaying":
                            player.performanceIsActuallyPlaying ? 1 : 0,
                        "playbackStalls": Double(
                            player.performancePlaybackStallCount - initialStallCount),
                    ]) { _, new in new },
                wallTime: Date(),
                monotonicNanoseconds: sampleTime)
        } while true

        let endWall = Date()
        let endMonotonic = monotonicNanoseconds()
        let finalSnapshot = ProcessSnapshot.capture()
        maximumFootprint = max(maximumFootprint, finalSnapshot.footprintMB)
        let finalConditions = conditions()
        if request.scenarioID == "playback.local"
            && (!player.performanceIsActuallyPlaying || !player.performanceSourceIsLocal) {
            playbackStopped = true
        }
        let playbackStalls = player.performancePlaybackStallCount - initialStallCount
        if playbackStalls > 0 {
            playbackStopped = true
        }
        var invalidReasons = invalidReasons(
            initial: initialConditions,
            final: finalConditions,
            request: request)
        let elapsed = Double(endMonotonic - measurementStartMonotonic) / 1_000_000_000
        // Silent locked scenarios are expected to suspend. Their sleep resumes on unlock after
        // the monotonic deadline; only background playback is required to finish on schedule.
        if request.scenarioID == "playback.local",
           abs(elapsed - request.durationSeconds) > max(5, request.durationSeconds * 0.02) {
            invalidReasons.append(
                "measurement duration drifted by \(elapsed - request.durationSeconds) seconds")
        }
        try recorder.emit(
            .phaseFinished,
            phase: phase,
            wallTime: endWall,
            monotonicNanoseconds: endMonotonic)

        var measurements = finalSnapshot.values(since: initialSnapshot)
        measurements.merge(workloadMeasurements) { _, workload in workload }
        measurements["maximumFootprintMB"] = maximumFootprint
        measurements["startFootprintMB"] = initialSnapshot.footprintMB
        measurements["endFootprintMB"] = finalSnapshot.footprintMB
        measurements["requestedDurationSeconds"] = request.durationSeconds
        measurements["observedDurationSeconds"] = elapsed
        measurements["deadlineOverrunSeconds"] = max(0, elapsed - request.durationSeconds)
        measurements["playbackStalls"] = Double(playbackStalls)
        if let startupMilliseconds {
            measurements["startupMilliseconds"] = startupMilliseconds
        }
        if let initialBattery = initialConditions.batteryLevel,
           let finalBattery = finalConditions.batteryLevel {
            measurements["batteryPercentagePointDrop"] =
                (initialBattery - finalBattery) * 100
        }

        let status: PerformanceRunStatus
        if playbackStopped {
            status = .failed
        } else if invalidReasons.isEmpty {
            status = .passed
        } else {
            status = .invalid
        }
        try recorder.finish(
            status: status,
            finalConditions: finalConditions,
            invalidReasons: playbackStopped
                ? invalidReasons + [PerformanceScenarioRunnerError.playbackStopped.localizedDescription]
                : invalidReasons,
            measurements: measurements,
            wallTime: endWall,
            monotonicNanoseconds: endMonotonic)
        if player.hasCurrent {
            player.stop(reason: "performance run complete")
        }
        UIApplication.shared.isIdleTimerDisabled = false
        publishPhase("Performance run complete.")
        fputs("PERF_RUN_COMPLETE \(recorder.directory.path)\n", stderr)
    }

    private struct DensePlannerFixtureResult {
        var meetingCount: Int
        var taskSourceCount: Int
        var occurrenceCount: Int
        var encodedBytes: Int
    }

    /// A fixed, executive-scale planner fixture for CPU/allocation regression testing. The real
    /// planner scenario remains the authority for EventKit I/O; this one holds content constant so
    /// a sparse personal calendar cannot make a materialization regression look inexpensive.
    private static func densePlannerFixture() throws -> DensePlannerFixtureResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_767_571_200)) // 2026-01-05 UTC
        let now = startDay.addingTimeInterval(6 * 60 * 60)

        var meetings: [MeetingInfo] = []
        meetings.reserveCapacity(14 * 12)
        for dayOffset in 0..<14 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay)!
            for slot in 0..<12 {
                let start = calendar.date(
                    byAdding: .minute,
                    value: 8 * 60 + slot * 45,
                    to: day)!
                let virtual = slot % 3 != 0
                meetings.append(MeetingInfo(
                    start: start,
                    end: start.addingTimeInterval(TimeInterval(slot.isMultiple(of: 4) ? 45 : 30) * 60),
                    coordinate: nil,
                    address: virtual ? nil : "\(100 + slot) Market Street",
                    isVirtual: virtual,
                    title: slot.isMultiple(of: 5) ? "Leadership review" : "Working session \(slot + 1)",
                    eventID: "fixture-event-\(dayOffset)-\(slot)",
                    joinURL: virtual ? URL(string: "https://meet.invalid/\(dayOffset)-\(slot)") : nil,
                    platform: nil,
                    calendarID: "fixture-calendar-\(slot % 4)"
                ))
            }
        }

        var tasks: [TaskInfo] = []
        tasks.reserveCapacity(240)
        for index in 0..<240 {
            let day = calendar.date(byAdding: .day, value: index % 14, to: startDay)!
            let due = calendar.date(
                byAdding: .minute,
                value: 7 * 60 + (index % 24) * 30,
                to: day)!
            let recurrence: CalendarItemRecurrence
            switch index % 4 {
            case 0: recurrence = .daily
            case 1: recurrence = .weekly
            default: recurrence = .never
            }
            tasks.append(TaskInfo(
                id: "fixture-task-\(index)",
                externalID: "fixture-external-task-\(index)",
                title: "Follow-up \(index + 1)",
                due: due,
                hasTime: index % 5 != 0,
                isCompleted: false,
                priority: (index % 5) + 1,
                recurrence: recurrence
            ))
        }

        var routines: [Routine] = [
            CueType.wake.makeRoutine(),
            CueType.workout.makeRoutine(),
            CueType.windDown.makeRoutine(),
            CueType.sleep.makeRoutine(),
            CueType.custom.makeRoutine(),
        ]
        let fixedRoutineIDs = [
            "10000000-0000-0000-0000-000000000001",
            "10000000-0000-0000-0000-000000000002",
            "10000000-0000-0000-0000-000000000003",
            "10000000-0000-0000-0000-000000000004",
            "10000000-0000-0000-0000-000000000005",
        ]
        for index in routines.indices {
            routines[index].id = UUID(uuidString: fixedRoutineIDs[index])!
        }
        routines[4].name = "Prepare"
        routines[4].triggerKind = .calendarMatch
        routines[4].matchKeywords = ["Leadership"]
        routines[4].leadMinutes = 10

        var wakeByDay: [Date: Date] = [:]
        for dayOffset in 0..<14 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay)!
            wakeByDay[day] = calendar.date(byAdding: .minute, value: 6 * 60 + 30, to: day)!
        }

        var materialized = OccurrenceProducers.external(meetings: meetings)
        materialized += OccurrenceProducers.tasks(
            tasks,
            horizonDays: 14,
            now: now,
            calendar: calendar)
        materialized += OccurrenceProducers.authored(
            routines: routines,
            wakeByDay: wakeByDay,
            horizonDays: 14,
            now: now,
            calendar: calendar)
        materialized += OccurrenceProducers.calendarBoundCues(
            routines: routines,
            meetings: meetings)
        materialized.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        let encoded = try JSONEncoder().encode(materialized)
        return DensePlannerFixtureResult(
            meetingCount: meetings.count,
            taskSourceCount: tasks.count,
            occurrenceCount: materialized.count,
            encodedBytes: encoded.count)
    }

    private static func makeArtworkFixture() -> Data {
        autoreleasepool {
            let size = CGSize(width: 1_800, height: 1_800)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.jpegData(withCompressionQuality: 0.88) { context in
                UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                for row in 0..<18 {
                    for column in 0..<18 {
                        let value = CGFloat((row * 31 + column * 17) % 97) / 96
                        UIColor(
                            hue: value,
                            saturation: 0.55 + CGFloat(row % 3) * 0.12,
                            brightness: 0.62 + CGFloat(column % 4) * 0.08,
                            alpha: 1
                        ).setFill()
                        context.fill(CGRect(
                            x: CGFloat(column * 100),
                            y: CGFloat(row * 100),
                            width: 100,
                            height: 100
                        ))
                    }
                }
            }
        }
    }

    private static func publishPhase(_ message: String) {
        NotificationCenter.default.post(
            name: .performanceScenarioPhase,
            object: message)
    }

    private static func writePreparationFailure(
        request: PerformanceScenarioRequest,
        error: Error
    ) {
        let now = Date()
        let monotonic = monotonicNanoseconds()
        let currentConditions = conditions()
        let manifest = PerformanceRunManifest(
            runID: request.runID,
            scenarioID: request.scenarioID,
            variant: request.variant,
            fixtureDigest: request.fixtureDigest,
            startedAt: now,
            monotonicStartNanoseconds: monotonic,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            gitCommit: request.gitCommit,
            configuration: "Release+PERFORMANCE_TESTING",
            device: device(),
            initialConditions: currentConditions)
        do {
            let recorder = try PerformanceRunRecorder(
                directory: runDirectory(runID: request.runID),
                manifest: manifest)
            try recorder.emit(
                .scenarioStarted,
                wallTime: now,
                monotonicNanoseconds: monotonic)
            try recorder.finish(
                status: .failed,
                finalConditions: currentConditions,
                invalidReasons: [error.localizedDescription],
                measurements: [:],
                wallTime: Date(),
                monotonicNanoseconds: monotonicNanoseconds())
            fputs("PERF_RUN_FAILED \(recorder.directory.path): \(error.localizedDescription)\n", stderr)
        } catch {
            fputs("PERF_RUN_UNRECORDED_FAILURE \(error)\n", stderr)
        }
    }

    private static func fixtureURL() throws -> URL {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("PerformanceFixtures", isDirectory: true)
        let supported = Set(["m4a", "mp3", "aac", "wav", "caf"])
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        guard let fixture = entries
            .filter({ supported.contains($0.pathExtension.lowercased()) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first else {
            throw PerformanceScenarioRunnerError.fixtureMissing
        }
        return fixture
    }

    private static func runDirectory(runID: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerformanceRuns", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    private static func invalidReasons(
        initial: PerformanceConditions,
        final: PerformanceConditions,
        request: PerformanceScenarioRequest
    ) -> [String] {
        var reasons: [String] = []
        if request.isTetheredMeasurement, initial.thermalState != final.thermalState {
            reasons.append(
                "thermal state changed during tethered measurement (\(initial.thermalState) → \(final.thermalState))")
        } else if !request.isTetheredMeasurement
            && (initial.thermalState != "nominal" || final.thermalState != "nominal") {
            reasons.append(
                "thermal state must remain nominal (was \(initial.thermalState) → \(final.thermalState))")
        }
        if initial.lowPowerMode || final.lowPowerMode {
            reasons.append("Low Power Mode must remain off for the baseline variant")
        }
        #if !targetEnvironment(simulator)
        if initial.batteryLevel == nil || final.batteryLevel == nil {
            reasons.append("battery level was unavailable")
        }
        if !request.isTetheredMeasurement
            && (initial.batteryState != "unplugged" || final.batteryState != "unplugged") {
            reasons.append(
                "device must be unplugged during measurement (was \(initial.batteryState) → \(final.batteryState))")
        }
        #endif
        if !request.isTetheredMeasurement
            && (request.scenarioID == "playback.local" || request.scenarioID == "planner.refresh")
            && (initial.network != "offline" || final.network != "offline") {
            reasons.append(
                "\(request.scenarioID) requires Airplane Mode/offline networking")
        }
        if initial.audioRoute != final.audioRoute {
            reasons.append(
                "audio route changed (\(initial.audioRoute) → \(final.audioRoute))")
        }
        return reasons
    }

    private static func conditions() -> PerformanceConditions {
        let batteryState: String
        switch UIDevice.current.batteryState {
        case .unknown: batteryState = "unknown"
        case .unplugged: batteryState = "unplugged"
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        @unknown default: batteryState = "unknown"
        }
        let network = NetworkMonitor.shared.isOnline
            ? (NetworkMonitor.shared.isConstrained
                ? "constrained"
                : (NetworkMonitor.shared.isExpensive ? "expensive" : "normal"))
            : "offline"
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .sorted()
            .joined(separator: ",")
        return PerformanceConditions(
            thermalState: thermalName(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: UIDevice.current.batteryLevel >= 0
                ? Double(UIDevice.current.batteryLevel)
                : nil,
            batteryState: batteryState,
            network: network,
            audioRoute: route.isEmpty ? "none" : route)
    }

    private static func device() -> PerformanceDevice {
        #if targetEnvironment(simulator)
        let platform = "iOS Simulator"
        #else
        let platform = "iOS"
        #endif
        return PerformanceDevice(
            platform: platform,
            model: sysctlString("hw.machine"),
            osVersion: UIDevice.current.systemVersion,
            osBuild: sysctlString("kern.osversion"))
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func batteryLevelForMeasurement() -> Double {
        UIDevice.current.batteryLevel >= 0 ? Double(UIDevice.current.batteryLevel) : -1
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        let value = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth(value).quotient
    }
}

private struct ProcessSnapshot {
    var cpuSeconds: Double
    var footprintMB: Double
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
    var timerWakeups: UInt64
    var syscalls: UInt64
    var contextSwitches: UInt64

    static func capture() -> ProcessSnapshot {
        var threadTimes = task_thread_times_info()
        var threadCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &threadTimes) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    $0,
                    &threadCount)
            }
        }
        var basic = task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_BASIC_INFO),
                    $0,
                    &basicCount)
            }
        }
        let cpu = Self.seconds(threadTimes.user_time)
            + Self.seconds(threadTimes.system_time)
            + Self.seconds(basic.user_time)
            + Self.seconds(basic.system_time)

        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }

        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }

        var events = task_events_info_data_t()
        var eventCount = mach_msg_type_number_t(
            MemoryLayout<task_events_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &events) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(eventCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &eventCount)
            }
        }
        return ProcessSnapshot(
            cpuSeconds: cpu,
            footprintMB: Double(vm.phys_footprint) / 1_048_576,
            interruptWakeups: power.task_interrupt_wakeups,
            idleWakeups: power.task_platform_idle_wakeups,
            timerWakeups: power.task_timer_wakeups_bin_1 + power.task_timer_wakeups_bin_2,
            syscalls: UInt64(max(0, events.syscalls_mach))
                + UInt64(max(0, events.syscalls_unix)),
            contextSwitches: UInt64(max(0, events.csw)))
    }

    func values(since start: ProcessSnapshot) -> [String: Double] {
        [
            "cpuSeconds": max(0, cpuSeconds - start.cpuSeconds),
            "footprintMB": footprintMB,
            "interruptWakeups": Double(Self.delta(interruptWakeups, start.interruptWakeups)),
            "idleWakeups": Double(Self.delta(idleWakeups, start.idleWakeups)),
            "timerWakeups": Double(Self.delta(timerWakeups, start.timerWakeups)),
            "syscalls": Double(Self.delta(syscalls, start.syscalls)),
            "contextSwitches": Double(Self.delta(contextSwitches, start.contextSwitches)),
        ]
    }

    private static func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }

    private static func delta(_ current: UInt64, _ start: UInt64) -> UInt64 {
        current >= start ? current - start : 0
    }
}
#endif
