import Foundation
import CoreText
import CoreGraphics

private final class CancellationPoll: @unchecked Sendable {
    let lock = NSLock()
    private(set) var count = 0
    func cancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count >= 40
    }
}

private final class Completion: @unchecked Sendable {
    let lock = NSLock()
    private var result: (finished: Double, produced: Bool) = (0, false)
    func record(produced: Bool) {
        lock.lock(); defer { lock.unlock() }
        result = (ProcessInfo.processInfo.systemUptime, produced)
    }
    func read() -> (finished: Double, produced: Bool) {
        lock.lock(); defer { lock.unlock() }; return result
    }
}

@main
struct TileCancellationChecks {
    @MainActor
    static func main() throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let model = PrototypeModel(store: store); model.move(to: store.anchor)
        let days = model.layouts
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        let region = CGRect(x: 0, y: 0, width: 1200, height: 256)
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        func render(_ cancelled: (@Sendable () -> Bool)? = nil) -> RasterPage? {
            RasterPage.render(days: days, width: 1200, height: 1920, gutter: 48, scale: 3,
                              style: style, region: region, cancelled: cancelled)
        }
        check(render({ true }) == nil, "Already-cancelled work allocated a result")
        let poll = CancellationPoll()
        check(render({ poll.cancelled() }) == nil && poll.count == 40, "Raster failed to stop during event traversal")
        let original = render()!, unchanged = render({ false })!
        check(original.ids == unchanged.ids, "Cancellation polling changed event IDs")
        check(original.image.dataProvider!.data! as Data == unchanged.image.dataProvider!.data! as Data,
              "Inactive cancellation changed pixels")
        var samples: [[String: Any]] = []
        let queue = OperationQueue(); queue.qualityOfService = .utility; queue.maxConcurrentOperationCount = 1
        for trial in 0..<7 {
            for cooperative in (trial.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let token = Operation(), result = Completion()
                let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
                queue.addOperation {
                    let cancel: (@Sendable () -> Bool)?
                    if cooperative { cancel = { token.isCancelled } }
                    else { cancel = nil }
                    started.signal()
                    let page = autoreleasepool {
                        RasterPage.render(days: days, width: 1200, height: 1920, gutter: 48,
                            scale: 3, style: style, region: region, cancelled: cancel)
                    }
                    result.record(produced: page != nil); finished.signal()
                }
                check(started.wait(timeout: .now() + 5) == .success, "Worker did not start")
                // This is an offscreen worker-stop probe. Blocking this CLI thread does not
                // represent the app's main-thread/input path or claim UI response latency.
                Thread.sleep(forTimeInterval: 0.001)
                let cancelTime = ProcessInfo.processInfo.systemUptime
                token.cancel()
                check(finished.wait(timeout: .now() + 5) == .success, "Worker failed to stop")
                let completion = result.read()
                samples.append(["trial": trial, "cooperative": cooperative,
                    "cancelToFinishMS": max(0, completion.finished - cancelTime) * 1000,
                    "completedBeforeCancel": completion.finished <= cancelTime,
                    "producedImage": completion.produced])
            }
        }
        try JSONSerialization.data(withJSONObject: ["scope": "Offscreen queue worker cancellation; not input latency",
            "checks": checks, "density": config.density, "samples": samples], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/tile-cancellation.json")))
        print("PASS: \(checks) cancellation/pixel/worker checks")
    }
}
