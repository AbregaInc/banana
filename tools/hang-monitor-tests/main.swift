import CoreFoundation
import Foundation
import os

// Compile this driver with the production MainRunLoopHangMonitor. It uses a real
// main run loop, including a nested mode which does not deliver common-mode observers.
let scenario = CommandLine.arguments[1]
let phase = OSAllocatedUnfairLock(initialState: "idle")
let reports = OSAllocatedUnfairLock(initialState: [(String, Double)]())
let threshold = 0.18
let watch = MainRunLoopHangMonitor(threshold: threshold, sample: { phase.withLock { $0 } }) { seconds, sample in
    reports.withLock { $0.append((sample ?? "missing stack", seconds)) }
}

func stall(_ label: String) {
    phase.withLock { $0 = label }
    Thread.sleep(forTimeInterval: 0.45)
    phase.withLock { $0 = "recovered" }
}

func nestedMode(stalls: Bool, refreshes: Bool) {
    let name = "app.fixture.nested"
    let mode = RunLoop.Mode(rawValue: name)
    phase.withLock { $0 = "healthy nested wait" }
    let exit = Timer(timeInterval: 0.58, repeats: false) { _ in
        if stalls { stall("private-mode timer") }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    RunLoop.main.add(exit, forMode: mode)
    var refresh: Timer?
    if refreshes {
        let timer = Timer(timeInterval: 0.015, repeats: true) { _ in phase.withLock { $0 = "healthy refresh" } }
        RunLoop.main.add(timer, forMode: mode)
        refresh = timer
    }
    CFRunLoopRunInMode(CFRunLoopMode(rawValue: name as CFString), 1.5, false)
    refresh?.invalidate()
    phase.withLock { $0 = "recovered" }
}

func blockObserver(_ activity: CFRunLoopActivity, order: Int) {
    let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, false, order) { _, _ in
        stall("run-loop observer")
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {}
}

let expected: [String: [String]] = [
    "idle": [], "late-layout": ["run-loop observer"], "early-input": ["run-loop observer"],
    "nested-idle": [], "nested-refresh": [], "nested-stall": ["private-mode timer"],
    "stop-restart": ["after restart"], "cancel-pending": [], "stop-after-recovery": ["left app"],
    "two-stalls": ["first", "second"]
]
guard let required = expected[scenario] else { fatalError("Unknown scenario \(scenario)") }
MainActor.assumeIsolated { watch.start() }
let start = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: false) { _ in
    switch scenario {
    case "late-layout": blockObserver(.beforeWaiting, order: 1000)
    case "early-input": blockObserver(.afterWaiting, order: -1000)
    case "nested-idle", "nested-refresh", "nested-stall":
        nestedMode(stalls: scenario == "nested-stall", refreshes: scenario == "nested-refresh")
    case "stop-restart":
        MainActor.assumeIsolated { watch.stop(); watch.stop() }
        stall("disabled")
        MainActor.assumeIsolated { watch.start(); watch.start() }
        stall("after restart")
    case "cancel-pending":
        stall("before stop")
        MainActor.assumeIsolated { watch.stop() }
    case "stop-after-recovery":
        // The person leaves the app: the run loop turns once after the stall, then stop() runs.
        stall("left app")
        DispatchQueue.main.async { MainActor.assumeIsolated { watch.stop() } }
    case "two-stalls":
        stall("first")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { stall("second") }
    default: break
    }
}
let finish = Timer.scheduledTimer(withTimeInterval: 1.85, repeats: false) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()
MainActor.assumeIsolated { watch.stop() }
let actual = reports.withLock { $0 }
let evidence: [String: Any] = [
    "scenario": scenario, "expectedLiveSamples": required,
    "reports": actual.map { ["sample": $0.0, "seconds": $0.1] as [String: Any] }
]
print(String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys), as: UTF8.self))
guard actual.map(\.0) == required, actual.allSatisfy({ $0.1 >= threshold }) else { exit(1) }
