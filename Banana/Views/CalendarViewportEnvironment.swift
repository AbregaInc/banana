import SwiftUI

private struct CalendarNativeCellKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SectionInFrontKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this page's section is the one on screen. The shell keeps the sections it has
    /// shown alive behind the one in front; a section that is not in front defers its expensive
    /// rebuilds until it is (the owner's rule, 26 Nov 2026: the screen in front comes first).
    var sectionInFront: Bool {
        get { self[SectionInFrontKey.self] }
        set { self[SectionInFrontKey.self] = newValue }
    }
    /// Native reusable cells have no SwiftUI scroll ancestor to report visibility.
    var calendarNativeCell: Bool {
        get { self[CalendarNativeCellKey.self] }
        set { self[CalendarNativeCellKey.self] = newValue }
    }
}

/// Both collection layouts keep one immutable attribute object per index path. A new event
/// at the same position can reuse that geometry; the adapters separately rebind its content.
enum CalendarViewportAttributes {
    /// Descriptors already contain the native frames. Inspect their contiguous values
    /// and return only the matching native objects, in their original paint order.
    static func visible<Item, Attribute>(_ attributes: [Attribute], items: [Item], rect: CGRect,
                                        active: Int?, frame: (Item) -> CGRect) -> [Attribute] {
        var hits: [Attribute] = []
        for index in items.indices where index == active || frame(items[index]).intersects(rect) {
            hits.append(attributes[index])
        }
        return hits
    }

    static func update<Item, Attribute>(_ attributes: inout [Attribute], from previous: [Item],
                                       to next: [Item], sameGeometry: (Item, Item) -> Bool,
                                       make: (Int, Item) -> Attribute) -> Bool {
        let common = min(previous.count, next.count)
        var changed = previous.count != next.count
        for index in 0..<common where !sameGeometry(previous[index], next[index]) {
            attributes[index] = make(index, next[index])
            changed = true
        }
        if next.count > common {
            attributes.reserveCapacity(next.count)
            for index in common..<next.count { attributes.append(make(index, next[index])) }
        } else if next.count < previous.count {
            attributes.removeLast(previous.count - next.count)
            if next.isEmpty { attributes = [] }
        }
        return changed
    }
}
