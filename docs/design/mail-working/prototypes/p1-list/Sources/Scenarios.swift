import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// The app drives itself: every scenario is started from a launch argument, on a timer after the
/// first frame has settled, records per display frame, writes one JSON file and logs one line.
@MainActor
final class ScenarioRunner {
    unowned let app: AppController
    var args: LaunchArgs { app.args }
    var model: InboxModel { app.model }
    var bridge: HostBridge? { model.bridge }
    let clock = DisplayClock()
    let turn = TurnTimer()

    struct Frame {
        var t: Double
        var dt: Double
        var sy: Double?          // SwiftUI's report of the marked row (global y)
        var ny: Double?          // UIKit / AppKit's answer for the same row (window y)
        var off: Double?         // the scroll view's own offset
        var phase: Int
        var moves: Int           // cursor moves since the previous frame
        var scrolled: Double     // points of intended scroll since the previous frame
        var slid: Int            // window re-centres since the previous frame
        var hasHost: Bool?       // a scroll view exists (recorded around a rebuild only)
    }

    private(set) var frames: [Frame] = []
    private var recording = false
    private var phase = 0
    private var tickCount = 0
    private var clockNow = 0.0
    private var t0 = 0.0
    private var frameDuration = 1.0 / 60
    private var movesSince = 0
    private var scrolledSince = 0.0
    private var slidSince = 0

    private struct Waiter { var ticks: Int?; var time: Double?; var c: CheckedContinuation<Void, Never> }
    private var waiters: [Waiter] = []

    init(app: AppController) { self.app = app }

    // MARK: Clock plumbing

    func start() {
        clock.onTick = { [weak self] t in self?.onTick(t) }
        clock.start()
    }

    private func onTick(_ t: DisplayClock.Tick) {
        tickCount += 1
        clockNow = t.time
        if t.frameDuration > 0 { frameDuration = t.frameDuration }
        if recording {
            var sy: Double?, ny: Double?, off: Double?
            if let pid = model.probedID {
                sy = Probe.y(for: pid).map(Double.init)
                if let wi = model.windowIndex(ofID: pid), let y = bridge?.groundTruthY(windowIndex: wi) { ny = Double(y) }
                off = bridge?.groundTruthOffset().map(Double.init)
            }
            frames.append(Frame(t: t.time - t0, dt: t.dt, sy: sy, ny: ny, off: off, phase: phase,
                                moves: movesSince, scrolled: scrolledSince, slid: slidSince,
                                hasHost: phase >= 3 ? (Introspect.scrollView() != nil) : nil))
            movesSince = 0; scrolledSince = 0; slidSince = 0
        }
        guard !waiters.isEmpty else { return }
        var ready: [Waiter] = [], rest: [Waiter] = []
        for w in waiters {
            if let n = w.ticks, tickCount >= n { ready.append(w) }
            else if let tm = w.time, t.time >= tm { ready.append(w) }
            else { rest.append(w) }
        }
        waiters = rest
        for w in ready { w.c.resume() }
    }

    private func ticks(_ n: Int) async {
        let target = tickCount + n
        await withCheckedContinuation { waiters.append(Waiter(ticks: target, time: nil, c: $0)) }
    }

    private func until(_ time: Double) async {
        await withCheckedContinuation { waiters.append(Waiter(ticks: nil, time: time, c: $0)) }
    }

    private func seconds(_ s: Double) async { await until(clockNow + s) }

    private func startRecording(phase p: Int) {
        frames.removeAll(keepingCapacity: true)
        phase = p
        t0 = clockNow
        movesSince = 0; scrolledSince = 0; slidSince = 0
        recording = true
    }

    private func stopRecording() { recording = false }

    private func waitForBridge() async {
        var n = 0
        while bridge == nil && n < 600 { await ticks(1); n += 1 }
    }

    // MARK: Running

    func run(_ name: String) async {
        start()
        await ticks(30)
        await waitForBridge()
        let cpu0 = cpuSeconds()
        let began = Date()
        var out: Outcome
        switch name {
        case "prepend": out = await prepend()
        case "rebuild": out = await rebuild()
        case "slide": out = await slide()
        case "heldkey": out = await heldkey(count: 2000, still: false)
        case "heldkey-still": out = await heldkey(count: 300, still: true)
        case "idle": out = await idle()
        case "debug": out = await debug()
        default: out = Outcome(summary: ["error": "unknown scenario \(name)"], pass: false, detail: [:])
        }
        out.summary["wallSeconds"] = Date().timeIntervalSince(began)
        out.summary["cpuSeconds"] = cpuSeconds() - cpu0
        write(name: name, outcome: out)
    }

    struct Outcome {
        var summary: [String: Any]
        var pass: Bool
        var detail: [String: Any]
    }

    /// Ground truth (UIKit / AppKit) exists for the two hosts that draw rows in a collection / table view.
    private var primaryIsNative: Bool { args.host != .lazy }

    /// The marked row's y by the probe that decides: UIKit/AppKit for the native host, SwiftUI's own
    /// report for the SwiftUI hosts. The other is kept as a cross-check.
    private func primary(_ f: Frame) -> Double? { primaryIsNative ? (f.ny ?? f.sy) : (f.sy ?? f.ny) }
    private func secondary(_ f: Frame) -> Double? { primaryIsNative ? f.sy : f.ny }

    private func lastValue(_ fs: [Frame], _ pick: (Frame) -> Double?) -> Double? {
        for f in fs.reversed() { if let v = pick(f) { return v } }
        return nil
    }

    // MARK: prepend

    private func prepend() async -> Outcome {
        let h = RowMetrics.height
        var reps: [[String: Any]] = []
        var worst = 0.0, worstCross = 0.0, anyMissingBaseline = false, totalMissing = 0
        model.reset()
        for rep in 0..<10 {
            model.setProbe(id: nil)
            // Row 50 at the top the way a person leaves it: scroll near, then a drag of exactly one row.
            // (`--via api` positions with the host's own API instead.)
            if args.via == "api" {
                bridge?.scroll(toOffset: 50 * h)
                await ticks(45)
            } else {
                bridge?.scroll(toOffset: 49 * h)
                await ticks(45)
                Introspect.nudge(by: h); bridge?.handScrolled()
                await ticks(30)
            }
            model.setProbe(id: model.rows[50].id)
            await ticks(30)
            startRecording(phase: 1)
            await ticks(12)
            let baseP = lastValue(frames, primary), baseS = lastValue(frames, secondary)
            let offBefore = frames.last?.off
            phase = 2
            let tInsert = clockNow
            let idBefore = model.probedID
            model.prepend(3)
            await until(tInsert + 2.0)
            stopRecording()
            guard let baseP else { anyMissingBaseline = true; reps.append(["rep": rep, "error": "no baseline"]); continue }
            let after = frames.filter { $0.phase == 2 }
            var maxAbs = 0.0, displaced = 0, missing = 0, firstDisp: Int?
            var series: [Double?] = []
            var crossSeries: [Double?] = [], offSeries: [Double?] = []
            for (i, f) in after.enumerated() {
                crossSeries.append(secondary(f).flatMap { y in baseS.map { ((y - $0) * 100).rounded() / 100 } })
                offSeries.append(f.off)
                if let y = primary(f) {
                    let d = y - baseP
                    maxAbs = max(maxAbs, abs(d))
                    if abs(d) > 0.5 { displaced += 1; if firstDisp == nil { firstDisp = i } }
                    series.append((d * 100).rounded() / 100)
                } else { missing += 1; series.append(nil) }
            }
            var crossMax = 0.0
            if let baseS { for f in after { if let y = secondary(f) { crossMax = max(crossMax, abs(y - baseS)) } } }
            worst = max(worst, maxAbs)
            totalMissing += missing
            worstCross = max(worstCross, crossMax)
            let finalD = after.last.flatMap(primary).map { $0 - baseP }
            reps.append(["rep": rep, "baseline": baseP, "maxAbsShift": maxAbs, "crossCheckMaxShift": crossMax,
                         "framesDisplaced": displaced, "firstDisplacedFrame": firstDisp as Any, "framesMissing": missing,
                         "finalShift": finalD as Any, "frames": after.count,
                         "offsetBefore": offBefore as Any, "offsetAfter": after.last?.off as Any,
                         "markedRow": idBefore as Any, "baselineCross": baseS as Any, "series": Array(series.prefix(60)),
                         "crossSeries": Array(crossSeries.prefix(60)), "offsetSeries": Array(offSeries.prefix(60)),
                         "dtSeries": Array(after.prefix(60).map { (($0.dt * 1000) * 10).rounded() / 10 })])
        }
        model.setProbe(id: nil)
        let pass = worst <= 0.5 && !anyMissingBaseline && totalMissing == 0   // the row leaving the screen is not 'did not move'
        return Outcome(summary: ["decidingNumber": worst, "decidingUnit": "pt: worst marked-row shift over 10 inserts",
                                 "crossCheckWorst": worstCross, "framesMarkedRowAbsent": totalMissing, "probe": primaryIsNative ? "UIKit/AppKit" : "SwiftUI onGeometryChange"],
                       pass: pass, detail: ["reps": reps])
    }

    // MARK: rebuild

    private func rebuild() async -> Outcome {
        let h = RowMetrics.height
        let frac: CGFloat = 23.68
        var reps: [[String: Any]] = []
        var worstFirst = 0.0, worstAfter = 0.0, maxBlankFrames = 0, maxBeforeHost = 0
        model.reset()
        for rep in 0..<5 {
            model.setProbe(id: nil)
            await waitForBridge()
            bridge?.scroll(toOffset: 137 * h)
            await ticks(45)
            // A drag ends at an offset nobody asked for: put every host at the fractional position the
            // same way (on the platform scroll view), not through the API under test.
            Introspect.nudge(by: frac); bridge?.handScrolled()
            await ticks(20)
            let id = model.rows[137].id
            model.setProbe(id: id)
            await ticks(30)
            startRecording(phase: 1)
            await ticks(12)
            let baseP = lastValue(frames, primary), baseS = lastValue(frames, secondary)
            let offBefore = bridge?.groundTruthOffset()
            // The app's discard: stamp, replace the whole tree with a blank view, wait, bring it back.
            model.restore = bridge?.stamp()
            let stamped = model.restore.map { "\($0.id)+\($0.points)" }
            phase = 2
            Probe.reset()
            app.showContent = false
            await seconds(3.0)
            phase = 3
            let restoreTime = clockNow
            app.showContent = true
            await until(restoreTime + 1.0)
            stopRecording()
            model.restore = nil
            guard let baseP else { reps.append(["rep": rep, "error": "no baseline"]); continue }
            let after = frames.filter { $0.phase == 3 }
            let first = after.first
            let firstP = first.flatMap(primary), firstS = first.flatMap(secondary)
            let firstPresent = after.firstIndex { primary($0) != nil }
            let firstHost = after.firstIndex { $0.hasHost == true }
            // Frames in which the list exists but the marked row is not in it yet: "a blank list followed by rows".
            let blankList = (firstHost != nil && firstPresent != nil) ? max(0, firstPresent! - firstHost!) : (firstHost != nil ? after.count - firstHost! : 0)
            let beforeHost = firstHost ?? after.count
            let presentDelta = firstPresent.flatMap { primary(after[$0]) }.map { $0 - baseP }
            let firstDelta = firstP.map { $0 - baseP }
            let crossDelta: Double? = (firstS != nil && baseS != nil) ? firstS! - baseS! : nil
            var maxAfter = 0.0
            var series: [Double?] = []
            for f in after {
                if let y = primary(f) { maxAfter = max(maxAfter, abs(y - baseP)); series.append(((y - baseP) * 100).rounded() / 100) }
                else { series.append(nil) }
            }
            // The deciding number: where the marked row is in the first frame it is on screen. Absent forever counts as a failure.
            worstFirst = max(worstFirst, presentDelta.map(abs) ?? .infinity)
            worstAfter = max(worstAfter, maxAfter)
            maxBlankFrames = max(maxBlankFrames, blankList)
            maxBeforeHost = max(maxBeforeHost, beforeHost)
            reps.append(["rep": rep, "baseline": baseP, "stamped": stamped as Any, "offsetBefore": offBefore as Any,
                         "firstPresentDelta": presentDelta as Any, "firstFrameDelta": firstDelta as Any, "firstFrameCrossDelta": crossDelta as Any,
                         "framesBeforeHost": beforeHost, "blankListFrames": blankList,
                         "framesUntilRowPresent": firstPresent ?? -1, "maxAbsDeltaAfterPresent": maxAfter,
                         "offsetFirstFrame": first?.off as Any, "offsetLast": after.last?.off as Any,
                         "frames": after.count, "series": Array(series.prefix(40))])
        }
        model.setProbe(id: nil)
        let pass = worstFirst <= 1.0 && maxBlankFrames == 0
        return Outcome(summary: ["decidingNumber": worstFirst.isFinite ? worstFirst : -1, "decidingUnit": "pt: worst |marked row y - before| on the first frame the row is on screen after restore (-1 = never)",
                                 "worstAfterPresent": worstAfter, "maxBlankListFrames": maxBlankFrames, "maxFramesBeforeHost": maxBeforeHost,
                                 "probe": primaryIsNative ? "UIKit/AppKit" : "SwiftUI onGeometryChange"],
                       pass: pass, detail: ["reps": reps])
    }

    // MARK: slide

    private func slide() async -> Outcome {
        let h = RowMetrics.height
        model.setProbe(id: nil)
        model.reset()
        bridge?.scroll(toOffset: 0)
        await ticks(45)
        model.setProbe(id: model.cursorID)
        await ticks(30)
        let slides0 = model.slides
        startRecording(phase: 1)
        let metro = Metronome()
        await metro.run(count: 600, hz: 30) { [unowned self] _ in
            let shift = model.moveCursor(by: 1)
            let moved = bridge?.reveal(windowIndex: model.cursorWindowIndex, direction: 1) ?? 0
            movesSince += 1
            scrolledSince += Double(moved)
            if shift != 0 { slidSince += 1 }
        }
        await ticks(20)
        stopRecording()
        let slides = model.slides - slides0
        let nyMissing = frames.filter { $0.ny == nil }.count, syMissing = frames.filter { $0.sy == nil }.count
        var jumps: [[String: Any]] = [], missing = 0, worst = 0.0, compared = 0
        var prev: Double?
        for f in frames {
            let y = primary(f)
            if let y, let p = prev {
                let expected = p + Double(h) * Double(f.moves) - f.scrolled
                let err = y - expected
                compared += 1
                worst = max(worst, abs(err))
                if abs(err) > 0.5 {
                    jumps.append(["t": f.t, "err": (err * 100).rounded() / 100, "moves": f.moves, "scrolled": f.scrolled, "slid": f.slid, "y": y, "prevY": p])
                }
            } else if y == nil && f.phase == 1 { missing += 1 }
            prev = y
        }
        // A scroll that lands one frame after the cursor move is a latency, not a jump. Count the frames that
        // match neither "scroll already applied" nor "scroll applied one frame late", re-basing after each.
        var realJumps: [[String: Any]] = []
        var lagFrames = 0
        do {
            var cumMoves = 0.0, cumScroll = 0.0, y0: Double?, corr = 0.0
            for f in frames {
                cumMoves += Double(f.moves); cumScroll += f.scrolled
                guard let y = primary(f) else { continue }
                if y0 == nil { y0 = y - Double(h) * cumMoves + cumScroll }
                let now = y0! + corr + Double(h) * cumMoves - cumScroll
                let late = y0! + corr + Double(h) * cumMoves - (cumScroll - f.scrolled)
                if abs(y - now) <= 0.5 { continue }
                if abs(y - late) <= 0.5 { lagFrames += 1; continue }
                realJumps.append(["t": f.t, "err": ((y - now) * 100).rounded() / 100, "slid": f.slid, "moves": f.moves, "scrolled": f.scrolled])
                corr += y - now
            }
        }
        let slideFrames = frames.enumerated().filter { $0.element.slid != 0 }.map { $0.offset }
        let jumpOnSlide = jumps.filter { ($0["slid"] as? Int ?? 0) != 0 }.count
        let pass = jumps.isEmpty && slides >= 2
        return Outcome(summary: ["decidingNumber": jumps.count, "decidingUnit": "frames where the cursor row is not where previous + intended scroll says",
                                 "worstError": worst, "framesCompared": compared, "framesMissing": missing, "framesTotal": frames.count, "nyMissing": nyMissing, "syMissing": syMissing, "windowRecentres": slides,
                                 "jumpsOnRecentreFrames": jumpOnSlide, "framesWithScrollOneFrameLate": lagFrames, "realJumpsAfterLagAllowance": realJumps.count,
                                 "realJumpMaxError": realJumps.map { abs($0["err"] as? Double ?? 0) }.max() ?? 0, "recentreFrameIndexes": slideFrames,
                                 "probe": primaryIsNative ? "UIKit/AppKit" : "SwiftUI onGeometryChange"],
                       pass: pass, detail: ["jumps": Array(jumps.prefix(40)), "realJumps": Array(realJumps.prefix(40))])
    }

    // MARK: heldkey

    private func heldkey(count: Int, still: Bool) async -> Outcome {
        model.setProbe(id: nil)
        model.reset()
        bridge?.scroll(toOffset: 0)
        await ticks(60)
        let before = Counters.snap()
        let slides0 = model.slides
        var callMs: [Double] = []
        turn.install()
        startRecording(phase: 1)
        let tStart = clockNow
        let metro = Metronome()
        await metro.run(count: count, hz: 30) { [unowned self] i in
            let d = still ? (i % 10 < 5 ? 1 : -1) : (i < count / 2 ? 1 : -1)
            let a = CACurrentMediaTime()
            turn.begin()
            model.moveCursor(by: d)
            _ = bridge?.reveal(windowIndex: model.cursorWindowIndex, direction: d)
            callMs.append((CACurrentMediaTime() - a) * 1000)
        }
        await ticks(30)
        stopRecording()
        turn.remove()
        let after = Counters.snap()
        let elapsed = clockNow - tStart
        let dts = frames.map(\.dt).filter { $0 > 0 }
        let hitches = dts.filter { $0 > 2 * frameDuration }.count
        let per10 = Double(hitches) / (elapsed / 10)
        let d = after.minus(before)
        let moves = Double(count)
        let rowPer = Double(d["rowBody"]!) / moves, markPer = Double(d["markBody"]!) / moves
        let pass: Bool
        if still {
            pass = d["container"] == 0 && d["rowBody"] == 0 && Double(d["markBody"]!) <= moves * 2 + 4 && per10 <= 3
        } else {
            // A window re-centre publishes the rows once, and a SwiftUI host that takes the rows as input
            // re-evaluates once for it (the design allows one list evaluation per applied change). What must
            // be zero is everything else: a container evaluation per move.
            pass = d["container"]! - (model.slides - slides0) <= 0 && per10 <= 3 && rowPer <= 1.5
        }
        return Outcome(summary: ["decidingNumber": d["container"]!, "decidingUnit": "container body evaluations during the held key",
                                 "moves": count, "hitches": hitches, "hitchesPer10s": per10, "frames": dts.count,
                                 "maxFrameMs": (dts.max() ?? 0) * 1000, "medianFrameMs": Stats.median(dts) * 1000,
                                 "p99FrameMs": Stats.percentile(dts, 0.99) * 1000,
                                 "containerDelta": d["container"]!, "containerExcessOverRecentres": d["container"]! - (model.slides - slides0), "updateDelta": d["update"]!,
                                 "rowBodyDelta": d["rowBody"]!, "markBodyDelta": d["markBody"]!,
                                 "rowBodyPerMove": rowPer, "markBodyPerMove": markPer,
                                 "moveCallMsMedian": Stats.median(callMs), "moveCallMsP95": Stats.percentile(callMs, 0.95),
                                 "turnMsMedian": Stats.median(turn.samples), "turnMsP95": Stats.percentile(turn.samples, 0.95),
                                 "turnMsMax": turn.samples.max() ?? 0, "turnSamples": turn.samples.count,
                                 "windowRecentres": model.slides - slides0, "elapsedSeconds": elapsed],
                       pass: pass, detail: [:])
    }

    // MARK: idle

    private func idle() async -> Outcome {
        model.setProbe(id: nil)
        model.reset()
        bridge?.scroll(toOffset: 0)
        await ticks(90)
        let before = Counters.snap()
        let cpu0 = cpuSeconds()
        let tick0 = tickCount
        await seconds(20)
        let d = Counters.snap().minus(before)
        let cpu = cpuSeconds() - cpu0
        let flat = d.values.allSatisfy { $0 == 0 }
        return Outcome(summary: ["decidingNumber": d.values.reduce(0, +), "decidingUnit": "body evaluations (all counters) over 20 s idle",
                                 "containerDelta": d["container"]!, "updateDelta": d["update"]!, "rowBodyDelta": d["rowBody"]!,
                                 "markBodyDelta": d["markBody"]!, "cpuSecondsIn20s": cpu, "framesIn20s": tickCount - tick0],
                       pass: flat, detail: [:])
    }

    // MARK: debug (not a measured scenario: prints what each probe says after a few scripted operations)

    private func debug() async -> Outcome {
        let h = RowMetrics.height
        func line(_ label: String) {
            let ys = (0..<4).map { bridge?.groundTruthY(windowIndex: $0).map { String(format: "%.1f", $0) } ?? "-" }
            let pid = model.probedID
            print("DEBUG \(label): [\(bridge?.debugString() ?? "")]")
            print("DEBUG \(label): known=\(bridge?.knownOffset ?? -1) truth=\(bridge?.groundTruthOffset().map { String(format: "%.2f", $0) } ?? "-") viewport=\(bridge?.viewportHeight ?? -1) rows0..3 y=\(ys) probe(\(pid.map(String.init) ?? "-"))=\(Probe.y(for: pid).map { String(format: "%.2f", $0) } ?? "-") class=\(Introspect.className())")
        }
        line("initial")
        model.setProbe(id: model.rows[0].id); await ticks(20); line("probe row0")
        for target in [CGFloat(50) * h, 137 * h + 23.68, 0, 10 * h] {
            bridge?.scroll(toOffset: target); await ticks(20); line("scroll(\(target))")
        }
        model.setProbe(id: model.rows[10].id); await ticks(20); line("probe row10")
        model.prepend(3); await ticks(2); line("prepend+2 ticks")
        await ticks(30); line("prepend+32 ticks")
        model.reset(); bridge?.scroll(toOffset: 0); await ticks(20)
        model.setProbe(id: model.cursorID); await ticks(20)
        for i in 0..<24 {
            let before = bridge?.knownOffset ?? -1
            model.moveCursor(by: 1)
            let moved = bridge?.reveal(windowIndex: model.cursorWindowIndex, direction: 1) ?? 0
            await ticks(3)
            let wi = model.cursorWindowIndex
            if i == 12 { print("DEBUG [\(bridge?.debugString() ?? "")]") }
            print("DEBUG move \(i): cursorIdx=\(wi) known \(before)->\(bridge?.knownOffset ?? -1) moved=\(moved) truth=\(bridge?.groundTruthOffset() ?? -1) viewport=\(bridge?.viewportHeight ?? -1) ny=\(bridge?.groundTruthY(windowIndex: wi).map { String(format: "%.1f", $0) } ?? "-") sy=\(Probe.y(for: model.probedID).map { String(format: "%.1f", $0) } ?? "-")")
        }
        return Outcome(summary: [:], pass: true, detail: [:])
    }

    // MARK: Output

    /// The native hosts have no variants.
    private var variantLabel: String { args.host == .native ? "-" : args.variant.rawValue }

    private var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif targetEnvironment(simulator)
        return "iOS-simulator"
        #else
        return "iOS-device"
        #endif
    }

    private func write(name: String, outcome: Outcome) {
        var doc: [String: Any] = [
            "host": args.host.rawValue, "variant": variantLabel, "scenario": name, "run": args.run,
            "platform": platform, "pass": outcome.pass, "summary": outcome.summary, "detail": outcome.detail,
            "load": ["uptime": args.uptime, "xcodebuildProcesses": args.xcodebuilds],
            "display": ["maxFPS": clock.maxFPS, "frameDurationMs": frameDuration * 1000],
            "scrollViewClass": Introspect.className(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "when": ISO8601DateFormatter().string(from: Date()),
        ]
        doc["counters"] = ["container": Counters.container, "rowBody": Counters.rowBody, "markBody": Counters.markBody]
        let clean = Self.sanitize(doc)
        let file = "\(args.host.rawValue)-\(variantLabel)-\(name)-r\(args.run).json"
        var url: URL
        #if os(macOS)
        if let out = args.out {
            url = URL(fileURLWithPath: out)
            if out.hasSuffix("/") || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { url = url.appendingPathComponent(file) }
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        }
        #else
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("p1-results")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(file)
        #endif
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        let s = outcome.summary
        let line = "P1 RESULT host=\(args.host.rawValue) variant=\(variantLabel) scenario=\(name) run=\(args.run) platform=\(platform) pass=\(outcome.pass) deciding=\(s["decidingNumber"] ?? "?") file=\(url.path)"
        print(line)
        NSLog("%@", line)
        #if os(macOS)
        fflush(stdout)
        exit(0)
        #endif
    }

    private static func sanitize(_ v: Any) -> Any {
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            guard let c = m.children.first else { return NSNull() }
            return sanitize(c.value)
        }
        switch v {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as CGFloat: return f.isFinite ? Double(f) : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let d as [String: Any]: return d.mapValues(sanitize)
        default: return v
        }
    }
}
