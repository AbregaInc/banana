var checks = 0
func check(_ ok: Bool, _ message: String) {
    checks += 1
    guard ok else { fatalError(message) }
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
let h = Harness()
var received: [CGFloat] = []
var deliveredDuringUpdate = false
h.week = Week { value in received.append(value); deliveredDuringUpdate = deliveredDuringUpdate || h.isUpdatingView }
h.sendHorizontalOffset(12)
check(received == [12], "Normal drag must deliver synchronously")
received = []
h.isUpdatingView = true
for value in 1...100 { h.sendHorizontalOffset(CGFloat(value)) }
check(received.isEmpty, "No publication inside a representable update")
h.isUpdatingView = false
drain()
check(received == [100], "Coalesce programmatic updates to the latest offset")
check(!deliveredDuringUpdate, "Deferred callback ran outside the view update")
received = []
h.isUpdatingView = true; h.sendHorizontalOffset(200); h.isUpdatingView = false
h.sendHorizontalOffset(300)
check(received == [300], "New drag must not wait for queued programmatic work")
drain()
check(received == [300], "Queued older offset must not overwrite a drag")
received = []
h.isUpdatingView = true; h.sendHorizontalOffset(400); h.isUpdatingView = false
h.week = nil
drain()
check(received.isEmpty, "Dismantled viewport cannot publish")
var released: Harness? = Harness()
weak var weakHarness = released
released?.week = Week { _ in fatalError("Released coordinator published") }
released?.isUpdatingView = true; released?.sendHorizontalOffset(500)
released = nil; drain()
check(weakHarness == nil, "Queued block must not retain the coordinator")
received = []
h.week = Week { received.append($0) }
h.sendHorizontalOffset(550, programmatic: true)
check(received.isEmpty, "UIKit layout offsets defer even after updateUIView returned")
drain()
check(received == [550], "UIKit layout offset is delivered after the layout transaction")
var deferredMS: [Double] = []
for _ in 0..<30 {
    let start = DispatchTime.now().uptimeNanoseconds
    h.week = Week { _ in deferredMS.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
    h.isUpdatingView = true; h.sendHorizontalOffset(600); h.isUpdatingView = false
    drain()
}
check(deferredMS.count == 30, "Every independent programmatic delivery completed")
var sink: CGFloat = 0
let callback: (CGFloat) -> Void = { sink += $0 }
h.week = Week(onHorizontalOffset: callback)
var directNS: [Double] = [], policyNS: [Double] = []
for i in 0..<12 {
    for candidate in (i % 2 == 0 ? [false, true] : [true, false]) {
        let start = DispatchTime.now().uptimeNanoseconds
        for value in 0..<100_000 {
            if candidate { h.sendHorizontalOffset(CGFloat(value)) } else { callback(CGFloat(value)) }
        }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / 100_000
        if candidate { policyNS.append(ns) } else { directNS.append(ns) }
    }
}
check(sink > 0, "Delivery benchmark consumed values")
let result: [String: Any] = ["checks": checks, "status": "pass", "deferredQueueMS": deferredMS,
    "directNSPerDelivery": directNS, "policyNSPerDelivery": policyNS,
    "scope": "Main-queue delivery and callback overhead; not frame or input-to-visible latency"]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Passed \(checks) header delivery checks")
