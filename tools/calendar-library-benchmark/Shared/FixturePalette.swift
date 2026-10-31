import CoreGraphics

// Identical calendar colors across candidate renderers; the frozen uniform
// workload continues using each renderer's original color.
enum FixturePalette {
    static let colors: [CGColor] = [
        (0.10, 0.40, 0.85), (0.75, 0.20, 0.25), (0.15, 0.60, 0.30),
        (0.55, 0.25, 0.75), (0.85, 0.45, 0.10), (0.10, 0.60, 0.65),
        (0.70, 0.25, 0.55), (0.45, 0.50, 0.15), (0.30, 0.35, 0.75),
        (0.65, 0.40, 0.20), (0.20, 0.55, 0.45), (0.55, 0.35, 0.45)
    ].map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    static let fills = colors.map { $0.copy(alpha: 0.15)! }
}
