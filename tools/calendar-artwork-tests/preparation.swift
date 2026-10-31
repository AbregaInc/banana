import SwiftUI

@main struct PreparationChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected new report path") }
        let path = CommandLine.arguments[1]
        guard !FileManager.default.fileExists(atPath: path) else { fatalError("Refusing overwrite") }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        let paint = CalendarEventPaint(title: "Actual event artwork", start: Date(timeIntervalSince1970: 1700000000),
            startText: "9:00", timeRange: "9:00–10:00", icon: "calendar")
        var environment = EnvironmentValues(); environment.displayScale = 2
        let size = CGSize(width: 100, height: 40)
        let cache = CalendarArtworkRasterCache(rendering: CalendarArtworkPreparation.applicationRendering)
        #if BANANA_BETA
        check(cache.preparationReport()["backend"] as? String == "native-core-text",
              "Beta must select the custom renderer without a launch opt-in")
        #else
        check(cache.preparationReport()["backend"] as? String == "swiftui-core-graphics",
              "Reference configuration must remain available for controlled comparison")
        #endif
        let firstStart = ContinuousClock.now
        let image = try cache.image(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment)
        let first = milliseconds(firstStart.duration(to: .now))
        let cost = image.bytesPerRow * image.height
        let budget = CalendarArtworkImageBudget(limit: cost)
        var lease = budget.acquire(image)
        check(lease != nil && budget.retainedBytes == cost, "Lease accounts exact bytes")
        check(budget.acquire(image) == nil, "Consumer budget rejects overflow")
        lease = nil
        check(budget.retainedBytes == 0, "Last consumer releases bytes")
        let preparation = CalendarArtworkPreparation(cache: cache, consumerByteLimit: cost, pendingLimit: 2, queuesCacheHits: true)
        let canceled = Task { @MainActor in
            await preparation.prepare(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment)
        }
        canceled.cancel()
        let cancellation = await canceled.value
        check(cancellation == nil && preparation.pendingCount == 0, "Canceled work cannot publish")

        var unsupported = environment
        unsupported.symbolRenderingMode = .multicolor
        let rejectedBefore = cache.statistics.rejected
        let unsupportedLease = await preparation.prepare(paint: paint, size: size,
            desktop: true, showsIcon: true, environment: unsupported)
        check(unsupportedLease == nil, "Unsupported symbols resolve as failure, not pending work")
        check(preparation.pendingCount == 0, "Unsupported environment leaves no queued work")
        check(cache.statistics.rejected == rejectedBefore + 1,
              "Unsupported environment must reach the explicit cache rejection")
        let recovery = CalendarArtworkPreparation(cache: cache)
        let recovered = await recovery.prepare(paint: paint, size: size,
            desktop: true, showsIcon: true, environment: environment)
        check(recovered != nil, "Returning to supported symbols can prepare the same event")

        // All three enqueue on the main actor before the delayed drain; the third must fall back.
        let a = Task { @MainActor in await preparation.prepare(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment) }
        let b = Task { @MainActor in await preparation.prepare(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment) }
        let c = Task { @MainActor in await preparation.prepare(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment) }
        var accepted = await a.value
        let refusedBudget = await b.value
        let refusedQueue = await c.value
        check(accepted != nil, "Queued visible work completes")
        check(refusedBudget == nil, "Queued work respects consumer budget")
        check(refusedQueue == nil, "Queue capacity requires live fallback")
        check(preparation.pendingCount == 0, "Queue drains")
        accepted = nil
        // A completed Task may own its result until its lifetime ends; measure with fresh
        // zero-cache coordinator below rather than assuming ARC shortens Task lifetime.
        let timed = CalendarArtworkPreparation(cache: cache)
        let queuedControl = CalendarArtworkPreparation(cache: cache, queuesCacheHits: true)
        var direct: [Double] = [], scheduled: [Double] = [], fast: [Double] = []
        for index in 0..<101 {
            for policy in index.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0] {
                let start = ContinuousClock.now
                if policy != 0 {
                    let coordinator = policy == 1 ? queuedControl : timed
                    let value = await coordinator.prepare(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment)
                    check(value != nil, "Scheduled sample completes")
                    let elapsed = milliseconds(start.duration(to: .now))
                    if policy == 1 { scheduled.append(elapsed) } else { fast.append(elapsed) }
                } else {
                    _ = try cache.image(paint: paint, size: size, desktop: true, showsIcon: true, environment: environment)
                    direct.append(milliseconds(start.duration(to: .now)))
                }
            }
        }
        // Model a replaced viewport: its cancellation callback is queued on the main
        // actor while a newly visible request asks for the last queue slot.
        var admission: [[String: Any]] = []
        for iteration in 0..<22 {
            let deferred = iteration.isMultiple(of: 2)
            var heldDrain: (@MainActor @Sendable () -> Void)?
            var holdDrain = true
            let coordinator = CalendarArtworkPreparation(cache: cache, pendingLimit: 1,
                queuesCacheHits: true, defersFullQueueAdmission: deferred,
                enqueueDrain: { work in
                    if holdDrain { heldDrain = work }
                    else { DispatchQueue.main.async(execute: work) }
                })
            let obsolete = Task { @MainActor in
                await coordinator.prepare(paint: paint, size: size, desktop: true,
                    showsIcon: true, environment: environment)
            }
            let enqueueDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while coordinator.pendingCount == 0 && ContinuousClock.now < enqueueDeadline {
                await Task.yield()
            }
            check(coordinator.pendingCount == 1,
                  "Replacement probe must observe queued work before its drain; synchronization missed")
            obsolete.cancel()
            holdDrain = false
            // Cancellation's actor callback and the drain both remain pending. Release
            // the drain through the real main queue before awaiting replacement admission.
            let drain = heldDrain!
            heldDrain = nil
            DispatchQueue.main.async(execute: drain)
            let start = ContinuousClock.now
            let replacement = await coordinator.prepare(paint: paint, size: size,
                desktop: true, showsIcon: true, environment: environment)
            let elapsed = milliseconds(start.duration(to: .now))
            let cancelledValue = await obsolete.value
            check(cancelledValue == nil, "Replaced viewport cannot publish cancelled artwork")
            check(coordinator.pendingCount == 0, "Replacement leaves no queued work")
            if deferred { check(replacement != nil, "One-turn admission reuses cancelled capacity") }
            admission.append(["deferred": deferred, "accepted": replacement != nil,
                "completionMS": elapsed, "deferrals": coordinator.queueAdmissionDeferrals,
                "rejections": coordinator.queueRejections])
        }
        // Force the race: drain synchronously after cancellation but before its queued
        // actor callback. The requesting task must reject the resulting image lease.
        var raceDrain: (@MainActor @Sendable () -> Void)?
        let raceCoordinator = CalendarArtworkPreparation(cache: cache, queuesCacheHits: true,
            enqueueDrain: { raceDrain = $0 })
        let race = Task { @MainActor in
            await raceCoordinator.prepare(paint: paint, size: size, desktop: true,
                showsIcon: true, environment: environment)
        }
        let raceDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while raceDrain == nil && ContinuousClock.now < raceDeadline { await Task.yield() }
        check(raceDrain != nil, "Cancellation race must enqueue its drain")
        race.cancel()
        raceDrain?()
        raceDrain = nil
        let racedValue = await race.value
        check(racedValue == nil, "Completed drain cannot return a cancelled lease")
        check(raceCoordinator.consumers.retainedBytes == 0, "Cancelled lease releases consumer bytes")
        let report: [String: Any] = ["backend": cache.preparationReport()["backend"]!, "checks": checks, "firstRenderMS": first,
            "replacementAdmission": admission,
            "directWarmMS": direct, "scheduledWarmMS": scheduled, "fastWarmMS": fast,
            "scope": "Preparation API completion only, including dispatch delay; not UI latency or frame delivery.",
            "consumerLimit": timed.consumers.limit, "pendingLimit": timed.pendingLimit]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("Passed \(checks) lifecycle checks; preparation timings retained at \(path)")
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
