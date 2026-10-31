var mismatches: [[String: String]] = []
var parityChecks = 0
for localeID in ["en_US", "en_GB", "fr_FR", "de_DE", "ja_JP", "ar_SA", "th_TH", "hi_IN", "zh_CN", "ko_KR"] {
    for zone in ["UTC", "America/New_York", "Asia/Kolkata", "Australia/Lord_Howe"] {
        for identifier: Calendar.Identifier in [.gregorian, .buddhist, .islamicUmmAlQura] {
            var cal = Calendar(identifier: identifier)
            cal.timeZone = TimeZone(identifier: zone)!
            let loc = Locale(identifier: localeID)
            for instant in [1_791_590_400.0, 1_767_225_600.0, 1_773_000_000.0] {
                let referenceNow = Date(timeIntervalSince1970: instant)
                for delta in [0, -1, -3, -15, -400] {
                    let date = cal.date(byAdding: .day, value: delta, to: referenceNow)!
                    for full in [false, true] {
                        let expected = full ? ReferenceMailDateText.full(date, calendar: cal, locale: loc)
                            : ReferenceMailDateText.row(date, now: referenceNow, calendar: cal, locale: loc)
                        let actual = full ? MailDateText.full(date, calendar: cal, locale: loc)
                            : MailDateText.row(date, now: referenceNow, calendar: cal, locale: loc)
                        parityChecks += 1
                        if actual != expected {
                            mismatches.append(["locale": localeID, "zone": zone, "calendar": String(describing: identifier),
                                               "date": String(date.timeIntervalSince1970), "full": String(full),
                                               "expected": expected, "actual": actual])
                        }
                    }
                }
            }
        }
    }
}
let parityURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("parity.json")
try JSONSerialization.data(withJSONObject: ["checks": parityChecks, "mismatches": mismatches], options: [.prettyPrinted, .sortedKeys]).write(to: parityURL)
if !mismatches.isEmpty { exit(1) }
