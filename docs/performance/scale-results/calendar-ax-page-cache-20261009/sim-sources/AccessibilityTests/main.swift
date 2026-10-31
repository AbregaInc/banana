import AppKit

@main
struct AccessibilityChecks {
    @MainActor
    static func main() throws {
        let config = Configuration(), store = FixtureStore(Configuration())
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 1200, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        let model = PrototypeModel(store: store)
        model.move(to: store.anchor)
        var checks = 0, samples: [[String: Any]] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        func elements() -> [NSAccessibilityElement] { surface.accessibilityChildren() as? [NSAccessibilityElement] ?? [] }
        func keyed() -> [String: NSAccessibilityElement] {
            Dictionary(uniqueKeysWithValues: elements().map { (String($0.accessibilityLabel()!.dropFirst(6)), $0) })
        }
        func verify() {
            check(surface.accessibilityCachedPages <= 3 && surface.accessibilityCachedElements <= 4096,
                  "Accessibility page cache exceeded its bound")
            let children = elements()
            let keys = children.map { String($0.accessibilityLabel()!.dropFirst(6)) }
            check(keys == surface.presentations.keys.sorted(), "Missing, duplicated, stale or misordered event children")
            for child in children {
                let key = String(child.accessibilityLabel()!.dropFirst(6))
                check(child.accessibilityFrameInParentSpace() == surface.presentations[key], "Stale frame after scroll/resize")
                check(child.accessibilityRole() == .button, "Event lost button semantics")
            }
        }
        func measure(_ phase: String, _ action: () -> Void) {
            let old = surface.accessibilityWorkMS, builds = surface.accessibilityCreatedElements
            let began = DispatchTime.now().uptimeNanoseconds
            action()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
            samples.append(["phase": phase, "totalMS": elapsed, "accessibilityMS": surface.accessibilityWorkMS - old,
                "createdElements": surface.accessibilityCreatedElements - builds, "retainedElements": elements().count,
                "peakResidentBytes": peakResidentBytes()])
            verify() // Correctness checks are deliberately outside timing.
        }
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        measure("cold") { surface.install(model.layouts, viewport: viewport) }
        let initial = keyed()
        for _ in 0..<100 {
            measure("samePage") { surface.install(model.layouts, viewport: viewport) }
        }
        if surface.optimizations.accessibilityReuse {
            let current = keyed()
            check(initial.allSatisfy { current[$0.key] === $0.value }, "Same page replaced accessible identities")
        }
        for step in 0..<120 {
            let before = keyed()
            let y = Double(step < 60 ? step : 119-step) / 59 * 1120
            measure("scroll") { surface.update(viewport: CGRect(x: 0, y: y, width: 1200, height: 800)) }
            if surface.optimizations.accessibilityReuse {
                let after = keyed()
                check(before.allSatisfy { after[$0.key] == nil || after[$0.key] === $0.value }, "Scroll replaced a surviving identity")
            }
        }
        for index in 0..<30 {
            let width: CGFloat = index.isMultiple(of: 2) ? 800 : 1200
            measure("resize") {
                document.frame.size.width = width
                surface.update(viewport: CGRect(x: 0, y: 0, width: width, height: 800))
            }
        }
        for _ in 0..<20 {
            measure("eviction") { surface.evictSpareViews(); surface.install(model.layouts, viewport: viewport) }
        }
        let oldChildren = elements()
        for index in 0..<20 {
            model.move(to: store.calendar.date(byAdding: .day, value: index.isMultiple(of: 2) ? 7 : 0, to: store.anchor)!)
            measure("page") { surface.install(model.layouts, viewport: viewport) }
            if index == 0 {
                check(!oldChildren.first!.accessibilityPerformPress(), "Off-page reference remained active")
                if surface.optimizations.accessibilityPageCache {
                    check(!oldChildren.first!.isAccessibilityElement(), "Cached off-page object remained exposed")
                }
            }
            let first = elements().first!
            check(first.accessibilityPerformPress(), "Event activation failed")
            check(surface.selectedID == String(first.accessibilityLabel()!.dropFirst(6)), "Activation selected wrong event")
        }
        let selected = surface.selectedID
        if surface.optimizations.accessibilityPageCache {
            let key = String(oldChildren.first!.accessibilityLabel()!.dropFirst(6))
            check(keyed()[key] === oldChildren.first!, "Returning page did not restore the same event identity")
            check(oldChildren.first!.isAccessibilityElement(), "Restored event remained hidden")
            let before = keyed()
            for offset in [7, 14, 21, 0] {
                model.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
                measure("cacheOrdering") { surface.install(model.layouts, viewport: viewport) }
            }
            if before.count * 3 <= 4096 {
                let restored = keyed()
                check(before.allSatisfy { restored[$0.key] === $0.value }, "Retiring current page evicted a requested hit")
            }
            for offset in stride(from: 28, through: 98, by: 7) {
                model.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
                measure("cacheEviction") { surface.install(model.layouts, viewport: viewport) }
            }
            surface.evictSpareViews()
            check(surface.accessibilityCachedPages == 0 && surface.accessibilityCachedElements == 0,
                  "Memory pressure retained off-page accessibility objects")
        } else {
            check(!oldChildren.first!.accessibilityPerformPress(), "Retired element reported successful activation")
            check(surface.selectedID == selected, "Retired element changed selection")
        }
        measure("empty") { surface.install([], viewport: viewport) }
        // install([]) must retire old content, even though update normally early-exits on empty days.
        check(elements().isEmpty, "Empty page retained accessible events")
        let report: [String: Any] = ["scope": "Offscreen AppKit component; no display/input evidence", "density": config.density,
            "ablation": surface.optimizations.disabled, "checks": checks, "samples": samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/accessibility-components.json")))
        print("PASS: \(checks) accessibility checks")
    }
}
