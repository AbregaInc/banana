import SwiftUI

/// One value+label pair: the list row's metric columns, the detail stat strip, the comparison
/// card. Drawn by the app-wide `StatValue` — label above, tabular digits, the unit split off at
/// its smaller size — so a workout's numbers look like every other number in Banana. A nil (or
/// "—") value shows the placeholder instead of omitting the tile, so a fixed set of tiles never
/// reflows when data availability differs per workout.
struct WorkoutMetricTile: View {
    let value: String?
    let label: String
    var alignment: HorizontalAlignment = .trailing
    var size: StatValue.Size = .tile
    /// A comparison under the value ("4 last week by now").
    var footnote: String? = nil

    var body: some View {
        let parts: (value: String?, unit: String?) = value.map(StatValue.split) ?? (nil, nil)
        StatValue(label: label, value: parts.value, unit: parts.unit, footnote: footnote, size: size, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// A left-to-right flow of subviews that WRAPS to a new line instead of clipping or forcing the
/// window wider — the fix for the detail hero's unbounded `HStack(spacing: 28)`, which already
/// clips at 5 of its up-to-12 possible metric pairs. Standard `Layout` wrap-by-width
/// implementation: lay subviews left to right, starting a new line whenever the next one would
/// overflow the proposed width.
struct WorkoutFlowLayout: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 12
    /// Offer each subview the line's width at most, so one too long for a line truncates on a
    /// line of its own instead of running off the edge. Off: each takes the size it asks for.
    var fitsWidth = false

    /// Its own size, or the line's width when it's wider than that: offered the whole line, a
    /// button takes all of it and every one sits on a line of its own.
    private func size(of subview: LayoutSubview, in width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard fitsWidth, width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, in: maxWidth)
            if x > 0, x + size.width > maxWidth {
                widestLine = max(widestLine, x - spacing)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widestLine = max(widestLine, x - spacing)
        y += lineHeight
        return CGSize(width: proposal.width ?? max(widestLine, 0), height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, in: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Consistent chrome + header for every chart card in the detail view: title, optional unit
/// label, fixed `WorkoutMetrics.chartHeight`, and an avg/max annotation slot. `cursorT` is the
/// shared scrub clock (spec §4.3) — this frame doesn't draw the cursor itself (a `RuleMark` has
/// to live inside the caller's own `Chart`), it just plumbs the same binding down to `content` so
/// every chart on the page reads and writes one shared value instead of maintaining its own.
struct WorkoutChartFrame<Content: View>: View {
    let title: String
    var unit: String? = nil
    var average: Double? = nil
    var maximum: Double? = nil
    var formatValue: (Double) -> String = { String(format: "%.0f", $0) }
    @Binding var cursorT: TimeInterval?
    @ViewBuilder var content: (Binding<TimeInterval?>) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content($cursorT)
                .frame(height: WorkoutMetrics.chartHeight)
        }
        .padding(WorkoutMetrics.cardPadding)
        .dsCard()
        .accessibilityIdentifier("workout.chart.\(title)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(WorkoutType.chartTitle)
            Spacer()
            if let annotation {
                Text(annotation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var annotation: String? {
        var parts: [String] = []
        if let average { parts.append("avg \(formatValue(average))\(unitSuffix)") }
        if let maximum { parts.append("max \(formatValue(maximum))\(unitSuffix)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var unitSuffix: String {
        guard let unit, !unit.isEmpty else { return "" }
        return " \(unit)"
    }
}

/// A detail card's title, inside the card: the same type and colour as a chart card's title
/// (`WorkoutChartFrame`, e.g. Heart rate), so every card on the detail page reads alike.
struct WorkoutSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(WorkoutType.chartTitle)
            .foregroundStyle(.primary)
    }
}

/// A single-line, muted notice used for every "not applicable" / "not on this Mac" state instead
/// of each section inventing its own wording and layout.
struct WorkoutSectionNote: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A workout's picture in a list, the same on every device: its route drawn as a line when GPS
/// recorded one that went somewhere (DESIGN-SYSTEM.md, the standard, 4), else its activity's
/// symbol in a tinted tile.
/// Non-interactive: the row's tap opens the workout.
struct WorkoutThumbnail: View {
    let activity: String
    let route: [RoutePoint]
    var size: CGFloat = DS.Row.thumbnail

    var body: some View {
        // A route that never left one place (a gym, a studio) is GPS jitter: the activity's
        // symbol says more than a scribble.
        if route.count > 1, !route.isOnePlace {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            RouteShape(route: route)
                .stroke(WorkoutPalette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(WorkoutPalette.accent.opacity(DS.Tint.soft), in: shape)
                .accessibilityHidden(true)
        } else {
            IconTile(systemImage: WorkoutActivityKind(activity: activity).systemImage,
                     tint: WorkoutPalette.accent, style: .soft, size: size)
        }
    }
}

/// A route drawn as a line, fitted into its frame with the aspect kept: no map tiles, labels or
/// "Legal" at thumbnail size. Longitude is scaled by cos(latitude) so shapes aren't stretched.
private struct RouteShape: Shape {
    let route: [RoutePoint]

    func path(in rect: CGRect) -> Path {
        guard route.count > 1 else { return Path() }
        let midLat = route.map(\.lat).reduce(0, +) / Double(route.count)
        let scaleX = cos(midLat * .pi / 180)
        let xs = route.map { $0.lon * scaleX }, ys = route.map { $0.lat }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return Path() }
        let spanX = max(maxX - minX, 1e-9), spanY = max(maxY - minY, 1e-9)
        let scale = min(rect.width / spanX, rect.height / spanY)
        let offX = rect.minX + (rect.width - spanX * scale) / 2
        let offY = rect.minY + (rect.height - spanY * scale) / 2
        var path = Path()
        for (i, (x, y)) in zip(xs, ys).enumerated() {
            // North up: larger latitude is higher on screen.
            let point = CGPoint(x: offX + (x - minX) * scale, y: offY + (maxY - y) * scale)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
