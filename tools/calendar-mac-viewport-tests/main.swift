import AppKit
import SwiftUI
import Foundation
setbuf(__stdoutp, nil)
let layout = CalendarMacCollectionLayout()
layout.size = CGSize(width: 1000, height: 2400)
layout.replaceItems((0..<240).map { index in
    CalendarMacViewportItem(id: String(index),
        frame: CGRect(x: (index % 10) * 100, y: (index / 10) * 100, width: 90, height: 90)) {
        AnyView(EmptyView())
    }
})
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
layout.replaceItems([])
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
// A page can replace all identities while preserving its geometry. A content update must
// still rebind the visible cells, even if it reuses every layout attribute.
let updates = CalendarMacCollectionViewport.Coordinator()
updates.scroll.frame = CGRect(x: 0, y: 0, width: 500, height: 250)
let updatedCollection = updates.scroll.documentView as! NSCollectionView
let updateLayout = updatedCollection.collectionViewLayout as! CalendarMacCollectionLayout
var contentReads = [Int: Int]()
func rows(page: Int, count: Int = 20, shifted: Int? = nil, raised: Int? = nil) -> [CalendarMacViewportItem] {
    (0..<count).map { i in
        CalendarMacViewportItem(id: "\(page)|\(i)",
            frame: CGRect(x: shifted == i ? 30 : 0, y: 50 * i, width: 300, height: 45),
            zIndex: raised == i ? 7 : 0) {
                contentReads[page, default: 0] += 1
                return AnyView(Text("Event \(page)/\(i)"))
            }
    }
}
func applyRows(_ items: [CalendarMacViewportItem], active: String? = nil, height: CGFloat = 1000) {
    updates.update(CalendarMacCollectionViewport(items: items, contentSize: CGSize(width: 500, height: height),
        background: AnyView(Color.clear), initialOffset: 0, activeID: active, onOffset: { _ in }),
        environment: EnvironmentValues())
    updates.scroll.layoutSubtreeIfNeeded()
    check(updatedCollection.numberOfItems(inSection: 0) == items.count)
    check(updateLayout.collectionViewContentSize.height == height)
    for (attributes, item) in zip(updateLayout.attributes, items) {
        check(attributes.frame == item.frame && attributes.zIndex == item.zIndex)
    }
}
applyRows(rows(page: 0))
let mountedAttributes = updateLayout.attributes
let initialReads = contentReads[0]!
applyRows(rows(page: 0), active: "19", height: 1100)
check(contentReads[0]! > initialReads)
check(zip(mountedAttributes, updateLayout.attributes).allSatisfy { $0 === $1 })
check(updateLayout.layoutAttributesForElements(in: .zero).contains { $0.indexPath?.item == 19 })
applyRows(rows(page: 1))
check(contentReads[1, default: 0] > 0 && updateLayout.activeIndex == nil)
check(zip(mountedAttributes, updateLayout.attributes).allSatisfy { $0 === $1 })
applyRows(rows(page: 1, shifted: 1, raised: 3))
check(zip(mountedAttributes, updateLayout.attributes).filter { $0 !== $1 }.count == 2)
applyRows(rows(page: 0))
applyRows([])
check(updateLayout.attributes.isEmpty)
updates.stopObserving()
// SwiftUI can update the coordinator before AppKit has given the viewport a size.
let opening = CalendarMacCollectionViewport.Coordinator()
opening.scroll.frame = .zero
func updateOpening(offset: CGFloat) {
    opening.update(CalendarMacCollectionViewport(items: [], contentSize: CGSize(width: 900, height: 1400),
        background: AnyView(Color.clear), initialOffset: offset, onOffset: { _ in }),
        environment: EnvironmentValues())
}
updateOpening(offset: 460)
opening.scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
opening.scroll.layoutSubtreeIfNeeded()
check(opening.scroll.contentView.bounds.minY == 460)
opening.scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
updateOpening(offset: 460)
check(opening.scroll.contentView.bounds.minY == 300)
opening.stopObserving()
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

// Background chrome must keep the event descriptor coordinate space even when
// AppKit independently narrows its native host to make room for a scrollbar.
func settle(_ view: NSView, until ready: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 2)
    repeat {
        view.layoutSubtreeIfNeeded()
        if ready() { return }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
    } while Date() < deadline
}
for style in [NSScroller.Style.legacy, .overlay] {
    let host = CalendarMacCollectionViewport.Coordinator()
    host.scroll.scrollerStyle = style
    host.scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
    var backgroundFrame: CGRect = .zero
    let background = AnyView(GeometryReader { geometry in
        let _ = { backgroundFrame = geometry.frame(in: .global) }()
        Color.clear
    })
    func update(width: CGFloat) {
        host.update(CalendarMacCollectionViewport(items: descriptors,
            contentSize: CGSize(width: width, height: 50000), background: background,
            initialOffset: 0, onOffset: { _ in }), environment: EnvironmentValues())
        settle(host.scroll) { backgroundFrame.width == width }
        check(backgroundFrame.width == width)
        check(backgroundFrame.minX == 0)
    }
    update(width: 900)
    for y in [400.0, 1200, 0] {
        host.scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        host.scroll.reflectScrolledClipView(host.scroll.contentView)
        settle(host.scroll) { backgroundFrame.width == 900 }
        check(backgroundFrame.width == 900)
        check(backgroundFrame.minX == 0)
    }
    host.scroll.frame.size.width = 1200
    update(width: 1200)
    let nativeBackground = (host.scroll.documentView as! NSCollectionView).backgroundView!
    nativeBackground.setFrameSize(CGSize(width: host.scroll.contentView.bounds.width, height: 50000))
    settle(nativeBackground) { backgroundFrame.width == 1200 }
    print("style=\(style.rawValue) hostWidth=\(nativeBackground.frame.width) gridFrame=\(backgroundFrame)")
    check(backgroundFrame.width == 1200)
    check(backgroundFrame.minX == 0)
    // Shrinking and expanding repeatedly should keep the document ruler attached
    // to the event geometry and leave the selected vertical range in place.
    host.scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
    host.scroll.reflectScrolledClipView(host.scroll.contentView)
    for width in [640.0, 1080, 680, 1200] {
        host.scroll.frame.size.width = width
        update(width: width)
        check(host.scroll.contentView.bounds.minY == 400)
    }
    host.stopObserving()
}
// Momentum can outlast the dominant axis, while resting fingers can pause a precise gesture.
// Neither starts another day or week. Wheels that supply no phase keep their timeout fallback.
var paging = CalendarMacPeriodSwipe()
check(paging.page(x: 35, y: 1, phase: .began, momentum: [], timestamp: 1) == nil)
check(paging.page(x: 30, y: 1, phase: .changed, momentum: [], timestamp: 1.02) == 1)
check(paging.page(x: 70, y: 0, phase: .changed, momentum: [], timestamp: 1.8) == nil)
check(paging.page(x: 75, y: 0, phase: [], momentum: .changed, timestamp: 2.5) == nil)
check(paging.page(x: -65, y: 0, phase: .began, momentum: [], timestamp: 2.51) == -1)
check(paging.page(x: 8, y: 75, phase: .began, momentum: [], timestamp: 3) == nil)
check(paging.page(x: 65, y: 4, phase: [], momentum: .began, timestamp: 3.12) == nil)
check(paging.page(x: 35, y: 1, phase: .began, momentum: [], timestamp: 4) == nil)
check(paging.page(x: 35, y: 0, phase: .cancelled, momentum: [], timestamp: 4.05) == nil)
check(paging.page(x: 36, y: 0, phase: [], momentum: [], timestamp: 5) == nil)
check(paging.page(x: 30, y: 0, phase: [], momentum: [], timestamp: 5.05) == 1)
check(paging.page(x: 65, y: 0, phase: [], momentum: [], timestamp: 5.8) == 1)
print("\(checks) AppKit layout, initial-mount and paging checks passed")
