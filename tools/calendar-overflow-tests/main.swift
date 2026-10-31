import Foundation

var checks = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) }
}
let anchor = Date(timeIntervalSince1970: 0)
func item(_ id: String, _ start: Double, _ end: Double) -> CalendarOverflowRules.Item {
    .init(id:id,start:anchor.addingTimeInterval(start*60),end:anchor.addingTimeInterval(end*60),title:"Event \(id)")
}
// Four overlapping events with distinct starts occupy four lanes. The fourth
// used to disappear: there was no same-start group larger than three.
let staggered = [item("a",0,60),item("b",5,65),item("c",10,70),item("d",15,75)]
let groups = CalendarOverflowRules.groups(staggered,hiddenIDs:["d"])
check(groups.count == 1, "Staggered fourth overlap has no overflow control")
check(groups[0].hidden == 1 && Set(groups[0].itemIDs) == Set(staggered.map(\.id)), "Overflow lost part of the overlapping group")
check(groups[0].start == staggered[3].start, "Overflow control does not align with the first hidden event")
let second = [item("e",120,180),item("f",125,185),item("g",130,190),item("h",135,195)]
let disjoint = CalendarOverflowRules.groups(staggered+second,hiddenIDs:["d","h"])
check(disjoint.count == 2 && disjoint.allSatisfy { $0.hidden == 1 }, "Unrelated overlap groups were merged")
check(CalendarOverflowRules.groups(staggered,hiddenIDs:[]).isEmpty, "No hidden events should produce no overflow")
let chain = staggered + [item("i",74,90),item("j",89,110)]
let connected = CalendarOverflowRules.groups(chain,hiddenIDs:["d"])
check(connected.count == 1 && Set(connected[0].itemIDs) == Set(chain.map(\.id)), "Connected overlap group lost events")
let simultaneous = (0..<9).map { item("\($0)",0,60) }
let simultaneousGroups = CalendarOverflowRules.groups(simultaneous,hiddenIDs:Set((3..<9).map(String.init)))
check(simultaneousGroups.count == 1 && simultaneousGroups[0].hidden == 6 && simultaneousGroups[0].itemIDs.count == 9, "Simultaneous overflow count changed")
// Boundary rule matches the lane allocator: less than a minute of overlap
// belongs to separate displayed clusters; exactly a minute remains connected.
check(CalendarOverflowRules.groups([item("a",0,60),item("b",59.5,90)],hiddenIDs:["a","b"]).count == 2,
      "Sub-minute overlap did not follow displayed-minute boundary")
check(CalendarOverflowRules.groups([item("a",0,60),item("b",59,90)],hiddenIDs:["a","b"]).count == 1,
      "One-minute overlap was split")
// Deterministic permutations must not alter row order or hidden counts.
for shift in 0..<staggered.count {
    let permuted = Array(staggered[shift...]) + Array(staggered[..<shift])
    let result = CalendarOverflowRules.groups(permuted,hiddenIDs:["b","d"])
    check(result.count == 1 && result[0].itemIDs == ["a","b","c","d"] && result[0].hidden == 2,
          "Source order changed overflow coverage")
}
let dense = (0..<10000).map { item("event-\($0)",Double($0 % 1440),Double($0 % 1440 + 60)) }
let omitted = Set(dense.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.id })
let denseGroups = CalendarOverflowRules.groups(dense,hiddenIDs:omitted)
let recovered = denseGroups.flatMap(\.itemIDs).filter { omitted.contains($0) }
check(Set(recovered) == omitted && recovered.count == omitted.count, "Dense overflow lost or duplicated an omitted event")
check(denseGroups.reduce(0) { $0 + $1.hidden } == omitted.count, "Dense hidden count mismatch")
print("PASS: \(checks) calendar overflow coverage checks")
