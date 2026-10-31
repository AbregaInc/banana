import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let locale = Locale(identifier: "en_US")
let now = Date(timeIntervalSince1970: 1_791_590_400)
let ages = [0, 1, 3, 15, 400]
func rows(_ count: Int, page: Int) -> [MailRow] {
    (0..<count).map { i in
        let date = calendar.date(byAdding: .day, value: -ages[i % ages.count], to: now)!
        return MailRow(id: MailConversationID(account: "probe@example.com", thread: "\(page)-\(i)"),
                       key: MailOrderKey(group: 0, sortKey: Int64(date.timeIntervalSince1970), tie: Int64(i)),
                       date: date, people: [MailPerson(name: "Sample Sender", address: "sender@example.com", isMe: false, isKnown: true, fromTheirMail: false)],
                       peopleTotal: 1, messageCount: 1 + i % 4,
                       subject: "Re: Fwd: Project \(i) — 会議", snippet: "A varied   snippet\nwith spacing and café \(i).",
                       isUnread: i % 3 == 0, isStarred: i % 19 == 0, isImportant: true,
                       hasAttachment: i % 5 == 0, isInvitation: i % 7 == 0, inInbox: true,
                       isMuted: false, hasPendingChange: false, fromGmailSearch: false, labels: [], reason: nil)
    }
}
var measurements: [[String: Any]] = []
var checksum = 0
for count in [100, 2_000] {
    let pages = [rows(count, page: 0), rows(count, page: 1)]
    var cache: [MailConversationID: MailRowDisplay] = [:]
    for phase in ["cold-working-set", "warm", "eviction-return"] {
        var samples: [Double] = []
        for iteration in 0..<10 {
            // Workload construction and explicit eviction are excluded from preparation timing.
            // This isolates the cost a pruned host must repay on a return to that page.
            if phase != "warm" { cache.removeAll(keepingCapacity: true) }
            let page = pages[phase == "eviction-return" ? iteration % 2 : 0]
            let start = DispatchTime.now().uptimeNanoseconds
            for row in page {
                if cache[row.id] == nil {
                    cache[row.id] = MailRowDisplay(row, now: now, calendar: calendar, locale: locale)
                }
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            precondition(cache.count == count)
            checksum += cache.values.reduce(0) { $0 + $1.subject.utf8.count + $1.date.utf8.count }
        }
        let ordered = samples.sorted()
        measurements.append(["rows": count, "phase": phase, "samplesMS": samples,
                             "p50MS": ordered[4], "p95MS": ordered[9], "maximumMS": ordered[9]])
    }
}
let report: [String: Any] = ["status": "measured-component-only", "measurements": measurements,
                            "checksum": checksum, "locale": locale.identifier, "timeZone": calendar.timeZone.identifier,
                            "limitations": "No UIKit/AppKit diffing or rendering. Cold working set is not process cold. Eviction and row creation are excluded. Not input-to-visible timing."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
