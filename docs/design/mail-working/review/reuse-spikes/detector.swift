import Foundation
// What NSDataDetector reads from the phrases MAIL-UX 6.5.2 lists. Fixed "now" is not injectable into
// NSDataDetector: it reads against the real clock, so results are printed relative to today.
let d = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
let f = DateFormatter(); f.dateFormat = "EEE yyyy-MM-dd HH:mm"
print("now:", f.string(from: Date()))
for s in ["tomorrow 8am", "8am", "17:30", "noon", "fri", "tomorrow", "aug 7", "12/3", "fri 3pm",
          "3 days", "2 weeks", "2h", "45 min", "tonight", "next week", "weekend", "in 3 days", "in 2 hours",
          "share availability", "monday 9", "next friday at 4"] {
    let r = NSRange(s.startIndex..., in: s)
    if let m = d.firstMatch(in: s, range: r), let date = m.date {
        let whole = m.range.length == r.length
        print(String(format: "%-20@ -> %@  (matched %d of %d chars%@, duration %.0f)", s as NSString, f.string(from: date), m.range.length, r.length, whole ? "" : " PARTIAL", m.duration))
    } else { print(String(format: "%-20@ -> nil", s as NSString)) }
}
