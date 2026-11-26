import SwiftUI

private struct CalendarNativeCellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
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
