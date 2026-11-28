import Foundation

// MacLocalInference runs its normal native launch, readiness and generation paths. Only
// the host app environment and the optional Apple model are replaced in this tiny executable.
enum AppSupport {
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_DIRECTORY"]!)
    static let isPiVerification = true
}
enum AssistantVerification { static let runIdentifier = "synthetic" }
enum AppleFoundationModel {
    static func generate(_ raw: String) async throws -> String { "Apple selected" }
}
@MainActor final class LocalModel {
    enum State { case missing, ready }
    static let shared = LocalModel()
    let state = State.missing
    let manifest: PinnedModelFiles.Manifest? = nil
}

@main struct VerifyMemoryGuard {
    @MainActor static func main() async throws {
        let unavailable = MacLocalInference.MemoryUnavailable()
        precondition(String(describing: unavailable) == unavailable.localizedDescription)
        let gib = MacInferenceMemory.gib
        let green = MacInferenceMemory(pressure: 1, headroom: 9 * gib, physicalBytes: 16 * gib)
        precondition(green.admits(weightBytes: 4 * gib, resident: false))
        precondition(!green.admits(weightBytes: 4 * gib + 1, resident: false))
        precondition(!green.admits(weightBytes: .max, resident: false))
        precondition(!green.admits(weightBytes: 0, resident: false))
        let warm = MacInferenceMemory(pressure: 1, headroom: green.reserve, physicalBytes: 16 * gib)
        precondition(warm.admits(weightBytes: 0, resident: true))
        precondition(!warm.admits(weightBytes: 1, resident: false))
        precondition(!MacInferenceMemory(pressure: 4, headroom: 100 * gib, physicalBytes: 16 * gib).admits(weightBytes: 1, resident: true))
        precondition(MacInferenceMemory.current() != nil)
        var swap = MacInferenceMemory.SwapWindow()
        let start = ContinuousClock.now
        let limit = MacInferenceMemory.SwapWindow.limit
        precondition(!swap.exceedsLimit(0, at: start))
        precondition(!swap.exceedsLimit(limit - 1, at: start.advanced(by: .seconds(1))))
        precondition(swap.exceedsLimit(limit, at: start.advanced(by: .seconds(2))))
        precondition(!swap.exceedsLimit(limit * 2, at: start.advanced(by: .seconds(12))))
        precondition(!swap.exceedsLimit(0, at: start.advanced(by: .seconds(13))))
        print("Passed cold and resident budgets, overflow, windowed system swap burst, pressure and live Darwin sampling")

        var sample: MacInferenceMemory? = nil
        var clock = ContinuousClock.now
        let host = MacLocalInference(currentMemory: { sample }, now: { clock })
        precondition(MacInferenceMemory(pressure: 1, headroom: 9 * gib, physicalBytes: 64 * gib).reserve == 4 * gib)
        precondition(MacInferenceMemory(pressure: 1, headroom: 9 * gib, physicalBytes: 256 * gib).reserve == 8 * gib)
        var memoryStops = 0
        let observer = NotificationCenter.default.addObserver(forName: MacLocalInference.memoryStopped,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { memoryStops += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let config = host.resolvedConfiguration()!
        let configURL = MacLocalInference.verificationConfigurationURL!
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        for value in [nil, 0.0, -1.0, 4.0] as [Double?] {
            document["promptCacheGiB"] = value
            let legacy = try JSONDecoder().decode(MacLocalInference.Configuration.self,
                from: JSONSerialization.data(withJSONObject: document))
            precondition(legacy.promptCacheArgument == "2")
        }
        // A smaller prompt cache must not lower the 2 GiB cold allowance or foreground reserve.
        let belowColdFloor = MacInferenceMemory(pressure: 1, headroom: green.reserve + 3 * gib, physicalBytes: green.physicalBytes)
        precondition(!belowColdFloor.admits(weightBytes: 1, resident: false))
        precondition(belowColdFloor.admits(weightBytes: 1, resident: true))
        precondition(!host.memoryAllows(config))
        do {
            try await host.startIfConfigured()
            fatalError("Unknown memory state admitted worker")
        } catch is MacLocalInference.MemoryUnavailable {}
        do { try await host.startIfConfigured(); fatalError("Second admission should still fail") }
        catch is MacLocalInference.MemoryUnavailable {}
        precondition(memoryStops == 1)
        let apple = try await host.generate("{}")
        precondition(apple == "Apple selected")
        let directory = URL(fileURLWithPath: config.modelDirectory)
        let pidFile = directory.appendingPathComponent("pid")
        precondition(!FileManager.default.fileExists(atPath: pidFile.path))
        print("Passed cold denial and explicit Apple generation")

        sample = green
        try await host.startIfConfigured()
        precondition(host.status["available"] as? Bool == true)
        sample?.swapoutBytes += limit
        try await host.startIfConfigured() // Idle worker does not claim background swap as its own.
        sample = warm
        precondition(host.memoryAllows(config))
        let expectedCache = ProcessInfo.processInfo.environment["EXPECTED_PROMPT_CACHE"]!
        let usedCache = try String(contentsOf: directory.appendingPathComponent("cache-argument"), encoding: .utf8)
        precondition(usedCache == expectedCache)
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        let request = #"{"backend":"mac-local","modelId":"test","instructions":"test","messages":[],"tools":[]}"#
        let pending = Task { try await host.generate(request) }
        let marker = directory.appendingPathComponent("request")
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(FileManager.default.fileExists(atPath: marker.path))
        sample = MacInferenceMemory(pressure: 2, headroom: 100 * gib, physicalBytes: 16 * gib)
        do {
            _ = try await pending.value
            fatalError("Accepted an interrupted generation")
        } catch is MacLocalInference.MemoryUnavailable {}
        precondition(host.status["available"] as? Bool == false)
        // The fake worker ignored SIGTERM and stalled inside generation; memory stop
        // must interrupt it. Verify the exact Process was reaped.
        let reap = ContinuousClock.now.advanced(by: .seconds(4))
        while kill(pid, 0) == 0 && ContinuousClock.now < reap { try await Task.sleep(for: .milliseconds(20)) }
        precondition(kill(pid, 0) == -1 && errno == ESRCH)
        do {
            _ = try await host.generate(request)
            fatalError("An explicit Mac request bypassed pressure guard")
        } catch is MacLocalInference.MemoryUnavailable {}
        print("Passed pressured in-flight abort, owned-child exit and no backend replay")

        sample = green
        for _ in 0..<3 {
            precondition(!host.memoryAllows(config))
            do { try await host.startIfConfigured(); fatalError("Restart during cooldown") }
            catch is MacLocalInference.MemoryUnavailable {}
            clock = clock.advanced(by: .seconds(10))
        }
        try await host.startIfConfigured()
        precondition(memoryStops == 2) // One stop event, despite repeated attempts.
        let recovered = try await host.generate(request)
        precondition(recovered.contains("fixture answer"))
        let nextPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        precondition(pid != nextPID)
        sample = MacInferenceMemory(pressure: 1, headroom: green.reserve - 1, physicalBytes: 16 * gib)
        precondition(host.memoryAllows(config))
        // Independent evidence: same HMAC worker survives low headroom and continues generation before pressure arrives.
        let residentAnswer = try await host.generate(request)
        precondition(residentAnswer.contains("fixture answer"))
        let samePID = Int32(try String(contentsOf: pidFile, encoding:.utf8))!
        precondition(samePID == nextPID)
        sample = MacInferenceMemory(pressure: 4, headroom: 0, physicalBytes: 16 * gib)
        let stop = ContinuousClock.now.advanced(by: .seconds(4))
        while host.status["available"] as? Bool == true && ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(host.status["available"] as? Bool == false)
        print("Passed cooldown, recovery, authenticated generation and continued resident low-headroom service, followed by pressure stop")
        while kill(nextPID, 0) == 0 && ContinuousClock.now < stop { try await Task.sleep(for: .milliseconds(20)) }
        precondition(kill(nextPID, 0) == -1 && errno == ESRCH)
        clock = clock.advanced(by: .seconds(31))
        sample = green
        try await host.startIfConfigured()
        try FileManager.default.removeItem(at: marker)
        let swapping = Task { try await host.generate(request) }
        let deadline2 = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(FileManager.default.fileExists(atPath: marker.path))
        sample?.swapoutBytes += limit
        do { _ = try await swapping.value; fatalError("Active swap burst was accepted") }
        catch is MacLocalInference.MemoryUnavailable {}
        let swappedPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        let reap2 = ContinuousClock.now.advanced(by: .seconds(4))
        while kill(swappedPID, 0) == 0 && ContinuousClock.now < reap2 { try await Task.sleep(for: .milliseconds(20)) }
        precondition(kill(swappedPID, 0) == -1 && errno == ESRCH)
        print("Passed in-flight host-wide swap burst stop under normal pressure and healthy headroom")
        sample = green
        clock = clock.advanced(by: .seconds(31))
        try await host.startIfConfigured()
        let gracefulPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        host.stop()
        let grace = ContinuousClock.now.advanced(by: .seconds(5))
        while kill(gracefulPID, 0) == 0 && ContinuousClock.now < grace { try await Task.sleep(for: .milliseconds(20)) }
        precondition(kill(gracefulPID, 0) == -1 && errno == ESRCH)
        print("Passed bounded graceful shutdown of an unresponsive child")

        try Data().write(to: directory.appendingPathComponent("hold-load"))
        let loading = Task { try await host.startIfConfigured() }
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        var loadingPID = gracefulPID
        while loadingPID == gracefulPID && ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
            loadingPID = Int32((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "") ?? gracefulPID
        }
        precondition(loadingPID != gracefulPID)
        sample?.swapoutBytes += limit
        do { try await loading.value; fatalError("Swap burst during preload was accepted") }
        catch is MacLocalInference.MemoryUnavailable {}
        let reapLoading = ContinuousClock.now.advanced(by: .seconds(4))
        while kill(loadingPID, 0) == 0 && ContinuousClock.now < reapLoading { try await Task.sleep(for: .milliseconds(20)) }
        precondition(kill(loadingPID, 0) == -1 && errno == ESRCH)
        print("Passed pre-readiness swap burst stop without triggering inference")
    }
}
