import AppKit
import SwiftUI
import Foundation
let layout = CalendarMacCollectionLayout()
layout.size = CGSize(width: 1000, height: 2400)
layout.attributes = (0..<240).map { i in
    let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
    a.frame = CGRect(x: (i % 10) * 100, y: (i / 10) * 100, width: 90, height: 90)
    return a
}
var checks = 0
func check(_ condition: Bool) { checks += 1; precondition(condition) }
check(layout.collectionViewContentSize == CGSize(width: 1000, height: 2400))
for y in stride(from: 0, through: 2400, by: 37) {
    let viewport = CGRect(x: 0, y: y, width: 1000, height: 350)
    let expected = layout.attributes.filter { $0.frame.intersects(viewport) }.compactMap(\.indexPath)
    check(layout.layoutAttributesForElements(in: viewport).compactMap(\.indexPath) == expected)
}
layout.activeIndex = 239
let top = CGRect(x: 0, y: 0, width: 1000, height: 300)
check(layout.layoutAttributesForElements(in: top).contains { $0.indexPath?.item == 239 })
layout.activeIndex = nil
check(!layout.layoutAttributesForElements(in: top).contains { $0.indexPath?.item == 239 })
check(layout.layoutAttributesForItem(at: IndexPath(item: 239, section: 0)) === layout.attributes[239])
check(layout.layoutAttributesForItem(at: IndexPath(item: 240, section: 0)) == nil)
check(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)) == nil)
layout.attributes = []
check(layout.layoutAttributesForElements(in: top).isEmpty)
// Windowless initial-mount checks exercise the actual adapter, without claiming that
// off-window scroll notifications model a visible AppKit window's lifecycle.
let coordinator = CalendarMacCollectionViewport.Coordinator()
coordinator.scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
var made = 0
var scrollEnds = 0
let descriptors = (0..<1000).map { i in
    CalendarMacViewportItem(id: String(i), frame: CGRect(x: 0, y: i * 50, width: 800, height: 45)) {
        made += 1
        return AnyView(Text("Event \(i)"))
    }
}
coordinator.update(CalendarMacCollectionViewport(items: descriptors,
    contentSize: CGSize(width: 900, height: 50000), background: AnyView(Color.clear),
    initialOffset: 0, onOffset: { _ in }, onScrollEnd: { scrollEnds += 1 }), environment: EnvironmentValues())
coordinator.scroll.layoutSubtreeIfNeeded()
let collection = coordinator.scroll.documentView as! NSCollectionView
check(collection.numberOfItems(inSection: 0) == 1000)
check(made > 0 && made < descriptors.count)
check(collection.visibleItems().count > 0)
check(collection.frame.height == 50000)
print("initialDescriptors=1000 contentCalls=\(made) visibleCells=\(collection.visibleItems().count)")
NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: coordinator.scroll.contentView)
check(scrollEnds == 0)
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: NSScrollView())
check(scrollEnds == 0)
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: coordinator.scroll)
check(scrollEnds == 1)
coordinator.update(CalendarMacCollectionViewport(items: [], contentSize: CGSize(width: 900, height: 600),
    background: AnyView(Color.clear), initialOffset: 0, onOffset: { _ in },
    onScrollEnd: { scrollEnds += 10 }), environment: EnvironmentValues())
coordinator.scroll.layoutSubtreeIfNeeded()
check(collection.numberOfItems(inSection: 0) == 0)
check(collection.visibleItems().isEmpty)
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: coordinator.scroll)
check(scrollEnds == 11)
coordinator.stopObserving()
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: coordinator.scroll)
check(scrollEnds == 11)
let wheel = CalendarMacScrollView()
var wheelEnds = 0
wheel.onDiscreteScrollEnd = { wheelEnds += 1 }
for _ in 0..<100 { wheel.scheduleDiscreteScrollEnd() }
check(wheelEnds == 0)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
check(wheelEnds == 1)
wheel.scheduleDiscreteScrollEnd()
wheel.stopScrollCallbacks()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
check(wheelEnds == 1)
print("\(checks) AppKit layout/initial-mount checks passed; no visible interaction or performance acceptance")
