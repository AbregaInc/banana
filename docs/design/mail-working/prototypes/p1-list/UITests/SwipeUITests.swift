import XCTest

/// What the app cannot do to itself: real touches. Per host: 20 full leading and 20 full trailing
/// swipes on rows (does the swipe action fire?), and vertical drags that *start on a row* (does the
/// enclosing scroll view still scroll?). The numbers go to results/uitest-<host>.txt and the test
/// fails when a swipe does not fire or a drag does not scroll.
final class SwipeUITests: XCTestCase {
    private let outDir = "/private/tmp/claude-501/-Users-owner-orca-workspaces-gtfuwgth-stingray/a2258f59-13ec-4139-b1e4-fd8203198777/scratchpad/prototypes/p1-list/results"

    override func setUp() { continueAfterFailure = true }

    func testListHost() { run(host: "list", variant: "reader", diy: false, expectSwipes: true) }
    func testNativeHost() { run(host: "native", variant: "positionY", diy: false, expectSwipes: true) }
    /// `LazyVStack` has no swipe actions: without a gesture the scroll is the baseline...
    func testLazyHostNoGesture() { run(host: "lazy", variant: "positionY", diy: false, expectSwipes: false) }
    /// ...and with the only thing one can build a swipe from, a drag gesture on the row, it is the measurement
    /// the app made before (a drag gesture on a row stops the enclosing scroll view on iOS 26).
    func testLazyHostDragGestureSwipe() { run(host: "lazy", variant: "positionY", diy: true, expectSwipes: true, tag: "lazy-diy") }
    /// The exact form the app measured as blocking the scroll: `.simultaneousGesture(DragGesture)`.
    func testLazyHostSimultaneousDragGestureSwipe() { run(host: "lazy", variant: "positionY", diy: true, expectSwipes: true, tag: "lazy-diy-simultaneous", simultaneous: true) }

    // MARK: -

    private struct Counts { var lead = 0, trail = 0 }

    private func counts(_ app: XCUIApplication) -> Counts {
        let label = app.staticTexts["swipe.counts"].label           // "lead=3 trail=2 last=Done#12"
        var c = Counts()
        for part in label.split(separator: " ") {
            if part.hasPrefix("lead=") { c.lead = Int(part.dropFirst(5)) ?? 0 }
            if part.hasPrefix("trail=") { c.trail = Int(part.dropFirst(6)) ?? 0 }
        }
        return c
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'row-'"))
    }

    private func visibleRows(_ app: XCUIApplication) -> [XCUIElement] {
        let q = rows(app)
        let window = app.windows.firstMatch.frame
        var out: [XCUIElement] = []
        for i in 0..<min(q.count, 30) {
            let e = q.element(boundBy: i)
            let f = e.frame
            if f.height > 20, f.minY > window.minY + 60, f.maxY < window.maxY - 60 { out.append(e) }
        }
        return out.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func run(host: String, variant: String, diy: Bool, expectSwipes: Bool, tag: String? = nil, simultaneous: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["--host", host, "--variant", variant, "--uitest"] + (diy ? [simultaneous ? "--diy-swipe-simultaneous" : "--diy-swipe"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["swipe.counts"].waitForExistence(timeout: 10))
        sleep(2)

        var report: [String] = []
        let name = tag ?? host

        // 1. Swipes: 20 full trailing (finger moves left) and 20 full leading (finger moves right).
        var firedTrailing = 0, firedLeading = 0
        if expectSwipes {
            for i in 0..<40 {
                let leading = i % 2 == 1
                let vis = visibleRows(app)
                guard vis.count > 3 else { report.append("swipe \(i): only \(vis.count) rows visible"); continue }
                let row = vis[2 + (i / 2) % max(1, min(5, vis.count - 3))]
                let before = counts(app)
                let a = row.coordinate(withNormalizedOffset: CGVector(dx: leading ? 0.08 : 0.92, dy: 0.5))
                let b = row.coordinate(withNormalizedOffset: CGVector(dx: leading ? 0.98 : 0.02, dy: 0.5))
                a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0)
                var after = counts(app)
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline, (leading ? after.lead == before.lead : after.trail == before.trail) {
                    usleep(100_000)
                    after = counts(app)
                }
                if leading { if after.lead == before.lead + 1 { firedLeading += 1 } }
                else { if after.trail == before.trail + 1 { firedTrailing += 1 } }
                usleep(300_000)
            }
        }
        report.append("swipes fired: trailing \(firedTrailing)/20, leading \(firedLeading)/20")

        // 2. Vertical drags that start on a row: does the content move?
        var scrolled = 0, trials = 10
        var moves: [CGFloat] = []
        let anchorCountsBefore = counts(app)
        for i in 0..<trials {
            let vis = visibleRows(app)
            guard vis.count > 3 else { continue }
            let row = vis[min(vis.count - 1, 4)]
            let id = row.identifier
            let beforeY = row.frame.minY
            let down = i % 2 == 1                       // drag content down every other time, so it never reaches the end
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: down ? 260 : -260))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            sleep(1)
            let same = rows(app).matching(identifier: id).firstMatch
            let moved: CGFloat = same.exists ? same.frame.minY - beforeY : (down ? 999 : -999)
            moves.append(moved)
            if abs(moved) > 100 { scrolled += 1 }
        }
        let anchorCountsAfter = counts(app)
        report.append("vertical drags from a row that scrolled the list: \(scrolled)/\(trials); moves=\(moves.map { Int($0) })")
        report.append("swipe actions fired by the vertical drags: \((anchorCountsAfter.lead - anchorCountsBefore.lead) + (anchorCountsAfter.trail - anchorCountsBefore.trail))")

        let text = "host=\(name)\n" + report.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? text.write(toFile: "\(outDir)/uitest-\(name).txt", atomically: true, encoding: .utf8)
        let att = XCTAttachment(string: text); att.lifetime = .keepAlways; add(att)

        if expectSwipes && !(diy) {
            XCTAssertEqual(firedTrailing, 20, "trailing swipes fired")
            XCTAssertEqual(firedLeading, 20, "leading swipes fired")
        }
        // The simultaneous-gesture variant records what the app measured; it is a finding, not an assertion.
        if !simultaneous { XCTAssertGreaterThanOrEqual(scrolled, trials - 1, "vertical drags from a row must scroll the list") }
    }
}
