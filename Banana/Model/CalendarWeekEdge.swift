import Foundation

/// A deliberate native rubber-band pull, never a projected fling, crosses a week.
enum CalendarWeekEdge {
    static func page(start: CGFloat, offset: CGFloat, maximum: CGFloat, width: CGFloat,
                     translation: CGPoint) -> Int? {
        guard [start, offset, maximum, width, translation.x, translation.y].allSatisfy(\.isFinite),
              maximum >= 0, width > 0,
              abs(translation.x) > abs(translation.y) * 1.25 else { return nil }
        let threshold = max(44, min(72, width * 0.16))
        if start <= 2, offset <= -threshold, translation.x > 0 { return -1 }
        if start >= maximum - 2, offset >= maximum + threshold, translation.x < 0 { return 1 }
        return nil
    }
}
