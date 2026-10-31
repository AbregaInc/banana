import UIKit

/// UIKit counterpart to the offscreen AppKit checks. This does not drive VoiceOver or measure UI latency.
@MainActor
enum AccessibilityProbe {
    static func run(_ config: Configuration) -> [String: Any] {
        let store = FixtureStore(config)
        let model = PrototypeModel(store: store)
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 1200, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        var checks = 0, failures: [String] = []
        var viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func elements() -> [UIAccessibilityElement] {
            if surface.optimizations.accessibilityLazy {
                return (0..<surface.accessibilityElementCount()).compactMap { surface.accessibilityElement(at: $0) as? UIAccessibilityElement }
            }
            return surface.accessibilityElements as? [UIAccessibilityElement] ?? []
        }
        func keyed() -> [String: UIAccessibilityElement] {
            Dictionary(elements().map { (String(($0.accessibilityLabel ?? "").dropFirst(6)), $0) },
                       uniquingKeysWith: { first, _ in first })
        }
        func verify() {
            let children = elements()
            check(children.map { String(($0.accessibilityLabel ?? "").dropFirst(6)) } == surface.presentations.keys.sorted(),
                  "Missing, stale, duplicate or misordered event elements")
            check(surface.accessibilityCachedPages <= 3 && surface.accessibilityCachedElements <= 4096,
                  "Retired accessibility cache exceeded its bound")
            for child in children {
                let key = String((child.accessibilityLabel ?? "").dropFirst(6))
                check(child.accessibilityFrameInContainerSpace == surface.presentations[key], "Stale event frame")
                check(child.accessibilityTraits.contains(.button) && child.isAccessibilityElement, "Lost event accessibility semantics")
            }
        }
        func move(_ offset: Int) {
            model.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
            surface.install(model.layouts, viewport: viewport)
            if checks == 0, surface.optimizations.accessibilityLazy {
                let count = surface.accessibilityElementCount()
                check(count > 0 && surface.accessibilityCreatedElements == 0, "Count eagerly created objects or omitted events")
                let first = surface.accessibilityElement(at: 0) as? UIAccessibilityElement
                check(first != nil && surface.accessibilityCreatedElements == 1, "First request did not materialize exactly one object")
                check((surface.accessibilityElement(at: 0) as? UIAccessibilityElement) === first, "Repeated query replaced identity")
                check(first.map { surface.index(ofAccessibilityElement: $0) == 0 } ?? false, "Wrong element index")
                check(surface.accessibilityElement(at: -1) == nil && surface.accessibilityElement(at: count) == nil,
                      "Out-of-range element request succeeded")
            }
            verify()
        }
        move(0)
        let original = keyed()
        check(!original.isEmpty, "No events to exercise")
        move(7)
        for old in original.values {
            check(!old.accessibilityActivate(), "Off-page event activated")
            if surface.optimizations.accessibilityPageCache {
                check(!old.isAccessibilityElement, "Cached off-page event remained exposed")
            }
            if surface.optimizations.accessibilityLazy {
                check(surface.index(ofAccessibilityElement: old) == NSNotFound, "Retired object retained an active index")
            }
        }
        move(0)
        if surface.optimizations.accessibilityPageCache {
            let returned = keyed()
            check(original.allSatisfy { returned[$0.key] === $0.value }, "Return replaced same-event identities")
        }
        if let first = elements().first {
            check(first.accessibilityActivate(), "Active event did not activate")
            check(surface.selectedID == String((first.accessibilityLabel ?? "").dropFirst(6)), "Wrong event selected")
        }
        let before = keyed()
        for offset in [7, 14, 21, 0] { move(offset) }
        if surface.optimizations.accessibilityPageCache && before.count * 3 <= 4096 {
            let returned = keyed()
            check(before.allSatisfy { returned[$0.key] === $0.value }, "Retiring page evicted a requested cache hit")
        }
        for offset in stride(from: 28, through: 98, by: 7) { move(offset) }
        for y in stride(from: 0, through: 1000, by: 100) {
            viewport.origin.y = CGFloat(y)
            surface.update(viewport: viewport)
            verify()
        }
        document.frame.size.width = 850
        viewport.size.width = 850
        surface.update(viewport: viewport)
        verify()
        surface.evictSpareViews()
        check(surface.accessibilityCachedPages == 0 && surface.accessibilityCachedElements == 0,
              "Memory pressure retained retired pages")
        verify()
        let retired = elements()
        surface.install([], viewport: viewport)
        verify()
        check(elements().isEmpty, "Empty page retained events")
        check(retired.allSatisfy { !$0.accessibilityActivate() }, "Empty page retained live actions")
        return ["scope": "Offscreen UIKit accessibility API checks; not VoiceOver navigation or input/display latency",
                "status": failures.isEmpty ? "pass" : "fail", "checks": checks, "failures": failures,
                "ablation": surface.optimizations.disabled, "density": config.density]
    }
}
