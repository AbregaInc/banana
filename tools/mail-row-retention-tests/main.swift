let ios = IOSHost(), mac = MacHost()
var samples: [[String: Any]] = []
var failures: [String] = []
for page in 0..<8 {
    let rows = (0..<64).map { MailRow(id: page * 64 + $0, title: "Message \(page * 64 + $0)") }
    ios.apply(rows, animated: false)
    let inFlightIOSRows = ios.rows.count
    ios.dataSource.finishAll()
    _ = mac.load(rows)
    let expected = Set(rows.map(\.id))
    for (platform, keys, displayKeys, order) in [
        ("iOS", Set(ios.rows.keys), Set(ios.displays.keys), ios.order),
        ("macOS", Set(mac.rows.keys), Set(mac.displays.keys), mac.order)
    ] {
        samples.append(["platform": platform, "scope": page, "visible": order.count,
                        "retainedRows": keys.count, "retainedDisplays": displayKeys.count,
                        "inFlightRows": platform == "iOS" ? inFlightIOSRows : keys.count])
        if Set(order) != expected { failures.append("\(platform) scope \(page): wrong visible IDs") }
        if keys != expected || displayKeys != expected {
            failures.append("\(platform) scope \(page): retained removed row/display IDs")
        }
    }
}
ios.apply([], animated: false); ios.dataSource.finishAll(); _ = mac.load([])
if !ios.rows.isEmpty || !ios.displays.isEmpty { failures.append("iOS empty scope retains previous data") }
if !mac.rows.isEmpty || !mac.displays.isEmpty { failures.append("macOS empty scope retains previous data") }
let transition = IOSHost()
let first = MailRow(id: 900, title: "First")
let second = MailRow(id: 901, title: "Second")
let updated = MailRow(id: 900, title: "Updated first")
let third = MailRow(id: 902, title: "Third")
transition.apply([first], animated: false); transition.dataSource.finishAll()
transition.apply([second], animated: true)
if transition.rows[first.id] == nil { failures.append("Outgoing row disappeared before its transition finished") }
transition.apply([updated], animated: true)
transition.apply([third], animated: true)
transition.dataSource.finish(0)
if transition.rows[first.id] != updated { failures.append("Old completion evicted a reinserted/re-retired row") }
transition.dataSource.finish(1)
if transition.rows[first.id] != nil { failures.append("Latest completed retirement failed to evict its row") }
transition.dataSource.finishAll()
if Set(transition.rows.keys) != [third.id] || Set(transition.displays.keys) != [third.id] {
    failures.append("Out-of-order completion leaked retired rows")
}
transition.apply([third, MailRow(id: third.id, title: "Duplicate")], animated: false)
transition.dataSource.finishAll()
if transition.rows[third.id] != third || transition.order != [third.id] { failures.append("Duplicate handling changed") }
var released: IOSHost? = IOSHost()
weak var weakHost = released
let retainedDataSource = released!.dataSource
released!.apply([first], animated: false)
released = nil
if weakHost != nil { failures.append("Pending snapshot completion retains the coordinator") }
retainedDataSource.finishAll()
var measurements: [[String: Any]] = []
if CommandLine.arguments.contains("--measure") {
    let pages = (0..<20).map { page in
        (0..<2000).map { MailRow(id: page * 2000 + $0, title: "Message \(page * 2000 + $0)") }
    }
    for platform in ["iOS", "macOS"] {
        let hostIOS = IOSHost(), hostMac = MacHost()
        let phases: [(String, [Int])] = [("cold", [0]), ("warm", Array(repeating: 0, count: 30)),
            ("replacement", Array(1..<20)), ("eviction-return", Array(repeating: [0, 19], count: 15).flatMap { $0 })]
        for (phase, indices) in phases {
            var times: [Double] = []
            var peakRows = 0
            for index in indices {
                let start = DispatchTime.now().uptimeNanoseconds
                if platform == "iOS" {
                    hostIOS.apply(pages[index], animated: false)
                    peakRows = max(peakRows, hostIOS.rows.count)
                    hostIOS.dataSource.finishAll()
                } else {
                    _ = hostMac.load(pages[index])
                    peakRows = max(peakRows, hostMac.rows.count)
                }
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            measurements.append(["platform": platform, "phase": phase, "samplesMS": times,
                "peakRetainedRows": peakRows, "settledRows": platform == "iOS" ? hostIOS.rows.count : hostMac.rows.count])
        }
    }
}
let report: [String: Any] = ["status": failures.isEmpty ? "pass" : "fail", "samples": samples,
    "failures": failures, "measurements": measurements, "scope": "Actual host dictionary membership; adapter types do not measure UI transitions, text, bytes or latency"]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Cache membership failures: \(failures.count)")
exit(failures.isEmpty ? 0 : 1)
