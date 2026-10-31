import Foundation

let baseValid = ["review", "--disable-icloud", "--plan", "--stress-actionable-calendar", "--stress-days", "90"]
let identifier = "com.boris.banana.stressreview"
var checks = 0
func check(_ expected: Bool, _ arguments: [String], _ bundleID: String? = identifier) {
    precondition(PhysicalStressReview.permits(arguments: arguments, bundleID: bundleID) == expected,
                 "Unexpected launch authorization: \(arguments), \(bundleID ?? "nil")")
    checks += 1
}
for route in ["--plan", "--mail"] {
    let valid = baseValid.map { $0 == "--plan" ? route : $0 }
    check(true, valid)
    for identity: String? in [nil, "com.boris.banana", "com.boris.banana.beta", "com.boris.banana.mac.stressreview"] {
        check(false, valid, identity)
    }
    for required in ["--disable-icloud", route, "--stress-actionable-calendar", "--stress-days"] {
        check(false, valid.filter { $0 != required })
    }
    for day in ["0", "-1", "366", "invalid", ""] {
        check(false, Array(valid.dropLast()) + [day])
    }
    for day in ["1", "365"] { check(true, Array(valid.dropLast()) + [day]) }
    check(false, Array(valid.dropLast()))
    for route in ["--day-real-calendar", "--verify-timeline", "--occurrences"] {
        check(false, valid + [route])
    }
    check(true, valid + ["--stress-calendar-fixture", "varied-v1", "--stress-events-per-day", "100"])
}
check(false, baseValid + ["--mail"])
print("Physical review launch policy: \(checks) checks passed")
