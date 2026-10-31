import XCTest

final class MailHoldRulesTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testNewestMessageAtTheEdgeHoldsTheWholeConversation() {
        let edge = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(MailHoldRules.holds(newestMessage: edge.addingTimeInterval(-0.001),
                                        attendedAt: nil, claims: [], edge: edge))
        for time in [edge, edge.addingTimeInterval(0.001)] {
            XCTAssertEqual(MailHoldRules.holds(newestMessage: time, attendedAt: nil,
                                              claims: [], edge: edge), .recentMail)
        }
    }

    func testAttentionExpiresAtTheMovingEdgeWithoutChangingMessageDates() {
        let edge = Date(timeIntervalSince1970: 1_800_000_000)
        let old = edge.addingTimeInterval(-1_000_000)
        XCTAssertNil(MailHoldRules.holds(newestMessage: old,
                    attendedAt: edge.addingTimeInterval(-0.001), claims: [], edge: edge))
        XCTAssertEqual(MailHoldRules.holds(newestMessage: old, attendedAt: edge,
                                          claims: [], edge: edge), .recentAttention)
        XCTAssertNil(MailHoldRules.holds(newestMessage: old, attendedAt: edge,
                                        claims: [], edge: edge.addingTimeInterval(1)))
    }

    func testEveryClaimAndCombinationRetainsOldMailUntilCleared() {
        let edge = Date(timeIntervalSince1970: 1_800_000_000)
        let old = edge.addingTimeInterval(-1_000_000)
        let singles: [MailClaims] = [.starred, .draft, .bananaLabel, .unfinishedSend,
                                    .pendingChange, .question, .keptAfterRemoval]
        XCTAssertEqual(Set(singles.map(\.rawValue)).count, 7)
        for raw in 1..<128 {
            let claims = MailClaims(rawValue: raw)
            XCTAssertEqual(MailHoldRules.holds(newestMessage: old, attendedAt: nil,
                                              claims: claims, edge: edge), .claim(claims))
        }
        XCTAssertNil(MailHoldRules.holds(newestMessage: old, attendedAt: nil,
                                        claims: [], edge: edge))
    }

    func testEverythingHasNoEdgeAndRetainsEvenAncientUnclaimedMail() {
        XCTAssertNil(MailHoldRules.edge(for: .everything, now: Date(), calendar: calendar()))
        XCTAssertEqual(MailHoldRules.holds(newestMessage: .distantPast, attendedAt: nil,
                                          claims: [], edge: nil), .everything)
    }

    func testOnlyExplicitClaimLabelsRetainMail() {
        let own: Set<String> = ["Label_9", "Label_10"]
        for label in ["STARRED", "DRAFT", "Label_9", "Label_10"] {
            XCTAssertTrue(MailHoldRules.isClaim(labelID: label, bananaLabelIDs: own))
        }
        for label in ["INBOX", "UNREAD", "IMPORTANT", "SENT", "TRASH", "SPAM",
                      "Label_11", "Banana/Snoozed/fake", "starred", ""] {
            XCTAssertFalse(MailHoldRules.isClaim(labelID: label, bananaLabelIDs: own))
        }
    }

    func testCalendarMonthsNotFixedDayDurations() {
        let c = calendar()
        let now = date(2026, 10, 10, 17, calendar: c)
        for (limit, month, year) in [(MailSyncLimit.oneMonth, 9, 2026),
                                    (.threeMonths, 7, 2026), (.sixMonths, 4, 2026),
                                    (.oneYear, 10, 2025)] {
            XCTAssertEqual(MailHoldRules.edge(for: limit, now: now, calendar: c),
                           date(year, month, 10, calendar: c))
        }
    }

    func testMonthEndAndLeapDayClampUsingTheCalendar() {
        let c = calendar()
        XCTAssertEqual(MailHoldRules.edge(for: .oneMonth,
            now: date(2024, 3, 31, 12, calendar: c), calendar: c), date(2024, 2, 29, calendar: c))
        XCTAssertEqual(MailHoldRules.edge(for: .oneMonth,
            now: date(2025, 3, 31, 12, calendar: c), calendar: c), date(2025, 2, 28, calendar: c))
        XCTAssertEqual(MailHoldRules.edge(for: .oneYear,
            now: date(2024, 2, 29, 12, calendar: c), calendar: c), date(2023, 2, 28, calendar: c))
    }

    func testEdgeIsStableWithinTheLocalDayAndMovesAcrossDST() throws {
        let c = calendar()
        for (month, day, hours) in [(4, 10, 23.0), (12, 3, 25.0)] {
            let now = date(2024, month, day, calendar: c)
            let next = c.date(byAdding: .day, value: 1, to: now)!
            let edge = try XCTUnwrap(MailHoldRules.edge(for: .oneMonth, now: now, calendar: c))
            XCTAssertEqual(MailHoldRules.edge(for: .oneMonth,
                now: next.addingTimeInterval(-0.001), calendar: c), edge)
            let nextEdge = try XCTUnwrap(MailHoldRules.edge(for: .oneMonth, now: next, calendar: c))
            XCTAssertEqual(nextEdge.timeIntervalSince(edge), hours * 3_600)
            XCTAssertEqual(c.startOfDay(for: edge), edge)
        }
    }

    func testEdgeUsesTheSuppliedTimezoneIncludingSkippedMidnight() throws {
        for zone in ["UTC", "Asia/Kathmandu", "America/Sao_Paulo", "Pacific/Apia"] {
            let c = calendar(zone)
            let now = date(2018, 12, 4, 12, calendar: c)
            let edge = try XCTUnwrap(MailHoldRules.edge(for: .oneMonth, now: now, calendar: c))
            XCTAssertEqual(edge, date(2018, 11, 4, calendar: c))
            XCTAssertEqual(edge, c.startOfDay(for: edge))
        }
    }
}
