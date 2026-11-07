#if DEBUG || MAIL_FIXTURES
import XCTest

/// What appending a page of older mail costs on the main thread, through the session: the
/// position the list reports, the model's decision, the in-memory source's read of the next
/// window, the model taking the reading in and publishing it. The list host's UIKit/AppKit
/// work and frame delivery are not in it (the host is not compiled into this bundle); the
/// scrolling-hitch UI case measures those on screen. Samples are retained as an attachment
/// (`mail-paging-append.json`) with their maximum, so a slow append is never averaged away.
@MainActor
final class MailPagingBenchmarkTests: XCTestCase {

    private struct Report: Encodable {
        var scope: String
        var rows: Int
        var appends: Int
        var samplesMS: [Double]
        var p50MS: Double
        var p95MS: Double
        var maxMS: Double
        var rowsAfter: [Int]
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func attach(_ name: String, _ report: Report) throws {
        let data = try JSONEncoder().encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MAIL PAGING BENCH \(name): \(String(data: data, encoding: .utf8) ?? "")")
    }

    /// Scrolls to the last loaded rows of a 4,000-conversation mailbox until the first browsing
    /// window is full: every step is one page appended below the rows on screen.
    func testAppendingAPageBelowTheRowsOnScreen() throws {
        var samples: [Double] = []
        var counts: [Int] = []
        for _ in 0..<5 {
            let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 2), defaults: nil)
            let session = MailSession(source: source, now: source.now, deviceName: "Test",
                                      timers: MailTimers { _, _ in {} }, present: { _, _ in })
            session.enter()
            while session.model.rows.count < MailTuning.listCap {
                let rows = session.model.rows
                let anchor = rows[max(0, rows.count - 8)]
                let before = rows.count
                samples.append(milliseconds {
                    session.send(.scrolled(MailViewport(firstRow: anchor.id, key: anchor.key, offset: 0)))
                })
                counts.append(session.model.rows.count)
                XCTAssertGreaterThan(session.model.rows.count, before, "every step appends a page")
                if session.model.rows.count <= before { break }
            }
            session.leave()
        }
        let sorted = samples.sorted()
        try attach("mail-paging-append", Report(
            scope: "MailSession + MailListModel + MailFixtureSource, main thread, no list host",
            rows: 4_000, appends: samples.count, samplesMS: samples,
            p50MS: percentile(sorted, 0.5), p95MS: percentile(sorted, 0.95), maxMS: sorted.last ?? 0,
            rowsAfter: counts))
    }

    /// Past the cap: each step lets go of the rows far above the screen and fills the window
    /// below (`MailPaging`), in a 6,000-conversation mailbox and a 2,000-row window. Not run
    /// against the commit before continuous scrolling, which had no slide.
    func testSlidingTheWindowBelowTheRowsOnScreen() throws {
        var samples: [Double] = []
        var counts: [Int] = []
        for _ in 0..<3 {
            let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 3), defaults: nil)
            let session = MailSession(source: source, now: source.now, deviceName: "Test",
                                      timers: MailTimers { _, _ in {} }, present: { _, _ in })
            session.enter()
            for _ in 0..<200 {
                let rows = session.model.rows
                let anchor = rows[max(0, rows.count - 12)]
                let window = session.model.windowBefore
                let time = milliseconds {
                    session.send(.scrolled(MailViewport(firstRow: anchor.id, key: anchor.key, offset: 0,
                                                        rowsOnScreen: 12)))
                }
                if session.model.windowBefore != window {
                    samples.append(time)
                    counts.append(session.model.rows.count)
                    XCTAssertLessThanOrEqual(session.model.rows.count, MailTuning.listCap)
                }
                if !session.feed.shown.hasMore, session.model.rows.last?.id == rows.last?.id { break }
            }
            session.leave()
        }
        XCTAssertGreaterThan(samples.count, 3)
        let sorted = samples.sorted()
        try attach("mail-paging-slide", Report(
            scope: "MailSession + MailListModel + MailFixtureSource, main thread, no list host",
            rows: 6_000, appends: samples.count, samplesMS: samples,
            p50MS: percentile(sorted, 0.5), p95MS: percentile(sorted, 0.95), maxMS: sorted.last ?? 0,
            rowsAfter: counts))
    }
}
#endif
