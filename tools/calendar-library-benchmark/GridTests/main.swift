import AppKit

@main
struct GridChecks {
    @MainActor
    static func main() throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let model = PrototypeModel(store: store)
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 800, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        let out = URL(fileURLWithPath: config.value("--output", "/tmp/calendar-grid-checks"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        var counts: [[String: Any]] = []
        for (index, spec) in [(800.0,0.0,0),(800,800,0),(1000,800,0),(1000,800,5),(1000,800,5),(800,0,0)].enumerated() {
            document.frame.size.width = spec.0
            model.move(to: store.calendar.date(byAdding: .day, value: spec.2, to: store.anchor)!)
            let viewport = CGRect(x: 0, y: spec.1, width: spec.0, height: 800)
            if index == 4 { surface.evictSpareViews() }
            surface.install(model.layouts, viewport: viewport)
            check(surface.expectedVisibleIDs(viewport).isSubset(of: Set(surface.presentations.keys)), "Missing visible events")
            if surface.optimizations.splitGrid {
                check(surface.splitGridFrame == CGRect(x: 0, y: 0, width: spec.0, height: 1920), "Stale grid width/height")
            }
            let bitmap = document.bitmapImageRepForCachingDisplay(in: viewport)!
            document.cacheDisplay(in: viewport, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: out.appendingPathComponent("\(index).png"))
            if config.args.contains("--reference") {
                let reference = URL(fileURLWithPath: config.value("--reference", "")).appendingPathComponent("\(index).png")
                let expected = NSBitmapImageRep(data: try Data(contentsOf: reference))!.cgImage!
                let actual = NSBitmapImageRep(data: png)!.cgImage!
                check(expected.width == actual.width && expected.height == actual.height &&
                      expected.dataProvider!.data! as Data == actual.dataProvider!.data! as Data,
                      "Split grid pixels differ from monolithic reference")
            }
            counts.append(["case":index,"gridInvalidations":surface.gridInvalidations,"gridDrawCount":surface.gridDrawCount,
                           "eventDrawCount":surface.eventDrawCount,"visibleCount":surface.expectedVisibleIDs(viewport).count])
        }
        let before = surface.gridInvalidations
        surface.install([], viewport: CGRect(x:0,y:0,width:800,height:800))
        check(surface.presentations.isEmpty, "Empty page retained events")
        if surface.optimizations.splitGrid { check(surface.gridInvalidations == before+1, "Day-column change did not invalidate grid") }
        try JSONSerialization.data(withJSONObject: ["checks":checks,"cases":counts], options:[.prettyPrinted,.sortedKeys])
            .write(to: out.appendingPathComponent("checks.json"))
        print("PASS: \(checks) grid lifecycle checks")
    }
}
