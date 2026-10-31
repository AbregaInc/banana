let center = NotificationCenter()
let pool = MailDateFormatterPool(center: center)
var lifecycleChecks = 0
func poolCheck(_ condition: Bool) { lifecycleChecks += 1; precondition(condition) }
for index in 0..<96 {
    var cal = calendar
    cal.timeZone = TimeZone(secondsFromGMT: index * 900)!
    let actual = pool.string("EEEdMMMjmm", now, cal, locale)
    poolCheck(actual == ReferenceMailDateText.full(now, calendar: cal, locale: locale))
    poolCheck(pool.retainedCount <= pool.capacity)
}
poolCheck(pool.retainedCount == pool.capacity)
center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
poolCheck(pool.retainedCount == 0)
_ = pool.string("EEE", now, calendar, locale)
center.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
poolCheck(pool.retainedCount == 0)
let parityLock = NSLock()
var concurrentFailures = 0
DispatchQueue.concurrentPerform(iterations: 128) { index in
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: (index % 48) * 900)!
    let loc = Locale(identifier: index.isMultiple(of: 2) ? "en_US" : "ar_SA")
    let date = Date(timeIntervalSince1970: 1_791_590_400 + Double(index * 3600))
    let expected = ReferenceMailDateText.full(date, calendar: cal, locale: loc)
    if index.isMultiple(of: 9) { pool.clear() }
    let actual = pool.string("EEEdMMMjmm", date, cal, loc)
    if actual != expected { parityLock.withLock { concurrentFailures += 1 } }
}
poolCheck(concurrentFailures == 0)
poolCheck(pool.retainedCount <= pool.capacity)
let poolURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("pool-checks.json")
try JSONSerialization.data(withJSONObject: ["checks": lifecycleChecks, "concurrentCases": 128,
                                            "concurrentFailures": concurrentFailures,
                                            "retainedFormatters": pool.retainedCount,
                                            "capacity": pool.capacity], options: [.prettyPrinted, .sortedKeys]).write(to: poolURL)
