import Foundation
struct Fixture: Decodable { var text: String; var scope: String; var terms: [String]?; var issues: Int? }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let rules = LiveFilterParser.compile(try Data(contentsOf: root.appendingPathComponent("Shared/LiveFilterRules.json")))
let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("tools/live-filter-tests/fixtures.json")))
for test in cases {
    let result = LiveFilterParser.parse(test.text, scope: test.scope, sources: [.init(id:"work-id",name:"Work")], rules: rules)
    let actual = result.terms.map { "\($0.field):\($0.op):\($0.value)" }.sorted()
    if let terms = test.terms { precondition(actual == terms.sorted(), "\(test.text): \(actual)") }
    precondition(result.issues.count == (test.issues ?? 0), "Issues for \(test.text): \(result.issues)")
}
let ambiguous = LiveFilterParser.parse("Work events", scope: "plan", sources: [.init(id:"a",name:"Work"),.init(id:"b",name:"Work")], rules: rules)
precondition(!ambiguous.canRun)
precondition(!LiveFilter(scope:"notes",terms:[.init(field:"bogus",op:"is",value:"yes")]).canRun)
let filter = LiveFilter(scope:"workouts",terms:[.init(field:"duration",op:"gt",value:"30"),.init(field:"kind",op:"is",value:"strength")])
precondition(filter.matches(date:Date(),text:"Strength",kind:"Traditional Strength Training",duration:1801))
precondition(!filter.matches(date:Date(),text:"Strength",kind:"Traditional Strength Training",duration:1800))
precondition(!filter.matches(date:Date(),text:"Running",kind:"Running",duration:2000))
precondition(LiveFilter.fromSearchExpression(filter.searchExpression,scope:"workouts")==filter)
precondition(LiveFilter.fromSearchExpression("banana-filter:broken",scope:"workouts")?.canRun==false)
var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/New_York")!;calendar.firstWeekday=2
let clock=ISO8601DateFormatter().date(from:"2026-03-08T16:00:00Z")!
let today=LiveFilter(scope:"notes",terms:[.init(field:"date",op:"in",value:"today")]).interval(now:clock,calendar:calendar)!
precondition(today.duration == 23*3600)
let next=LiveFilter(scope:"notes",terms:[.init(field:"date",op:"in",value:"nextWeek")]).interval(now:clock,calendar:calendar)!
precondition(calendar.component(.weekday,from:next.start)==2)
var timings:[Double]=[]
for _ in 0..<1000 { let start=ProcessInfo.processInfo.systemUptime; _=LiveFilterParser.parse(cases[0].text,scope:"plan",sources:[.init(id:"work-id",name:"Work")],rules:rules);timings.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
let sorted=timings.sorted()
print("\(cases.count) shared phrase fixtures; ambiguity, duration, invalid version/fields, transport and DST checks passed")
print("Parser only, 1000 warm samples (ms): p50=\(sorted[500]) p95=\(sorted[950]) p99=\(sorted[990]) max=\(sorted.last!). Not UI latency.")

let rows = (0..<10000).map { i in (Date(timeIntervalSince1970: Double(i)), i % 2 == 0 ? "Traditional Strength Training" : "Running", Double(i % 3600)) }
var directSamples: [Double] = [], preparedSamples: [Double] = []
for i in 0..<7 {
    var counts: [Int] = []
    for prepared in i.isMultiple(of: 2) ? [false,true] : [true,false] {
        let start = ProcessInfo.processInfo.systemUptime
        let match = filter.predicate()
        let count = rows.filter { prepared ? match($0.0,$0.1,$0.1,$0.2) : filter.matches(date:$0.0,text:$0.1,kind:$0.1,duration:$0.2) }.count
        let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
        if prepared { preparedSamples.append(ms) } else { directSamples.append(ms) }
        counts.append(count)
    }
    precondition(counts[0] == counts[1])
}
print("10,000-row predicate preparation ablation, identical results. Per-row preparation ms: \(directSamples); once-per-query ms: \(preparedSamples). Not UI latency.")
if CommandLine.arguments.count > 2 {
    let report: [String: Any] = ["fixtures": cases.count, "parserWarmMS": timings, "perRowPreparationMS": directSamples, "oncePerQueryMS": preparedSamples, "scope": "Host component checks during other builds; not UI or quiet-host acceptance"]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}
