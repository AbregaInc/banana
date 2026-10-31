var checks = 0
func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
var changed: CGSize?, ended: CGSize?, cancellations = 0, constructions = 0
let item = CalendarViewportItem(id: "overnight", frame: CGRect(x: 120, y: 40, width: 40, height: 60),
    zIndex: 7, retainsActiveGesture: true, allowsHitTesting: false,
    move: CalendarViewportMove(id: "overnight", columnWidth: 100,
        changed: { changed = $0 }, ended: { ended = $0; return true }, cancelled: { cancellations += 1 })) {
    constructions += 1; return AnyView(Text("original title"))
}
let first = item.namespaced("2026-10-10"), second = item.namespaced("2026-10-11")
check(first.id != second.id, "overnight cells must be distinct")
check(first.move?.id == first.id && second.move?.id == second.id, "preview tracking must follow cell identity")
check(first.frame == item.frame && first.zIndex == item.zIndex, "namespace preserves geometry/order")
check(first.retainsActiveGesture && !first.allowsHitTesting, "namespace preserves interaction flags")
first.move?.changed(CGSize(width: 2, height: 3)); check(changed == CGSize(width: 2, height: 3), "change reaches original callback")
check(second.move!.ended(CGSize(width: 4, height: 5)), "move result preserved")
check(ended == CGSize(width: 4, height: 5), "end reaches original callback")
second.move?.cancelled(); check(cancellations == 1, "cancel reaches original callback")
let column = CGRect(x: 100, y: 0, width: 50, height: 100)
let clip = item.clipped(to: column)!
check(clip.frame == CGRect(x: 120, y: 40, width: 30, height: 60), "right edge clipping")
check(clip.id == item.id && clip.move?.id == item.id, "clipping preserves event identity")
check(clip.retainsActiveGesture && !clip.allowsHitTesting && clip.zIndex == 7, "clipping preserves action state")
check(item.clipped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))!.frame == item.frame, "full containment")
check(item.clipped(to: CGRect(x: 160, y: 0, width: 100, height: 100)) == nil, "touching edge is not visible")
check(item.clipped(to: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil, "off-column artwork omitted as in reference")
for x in stride(from: -100.0, through: 300, by: 5) {
    let region = CGRect(x: x, y: 50, width: 30, height: 20)
    let expected = item.frame.intersection(region)
    let actual = item.clipped(to: region)
    check(actual?.frame == (expected.isNull || expected.isEmpty ? nil : expected), "viewport intersection \(x)")
}
check(constructions == 0, "geometry/identity preparation must not instantiate offscreen artwork")
_ = clip.content(); check(constructions == 1, "visible content uses original callback")
try JSONSerialization.data(withJSONObject: ["checks":checks,"scope":"Actual descriptor identity, geometry and callback helpers; no UIKit recycling, pixels or UI latency."],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
print("Passed \(checks) viewport descriptor checks")
