import SwiftUI
import Charts

/// Sleep per night as a bar chart with its average drawn in, and one line only when weekends
/// are repaying a weekday debt. Lifted out of the
/// retired Rhythm screen so the morning briefing and the post-workout review can share it.
struct SleepWeekCard: View {
    let sleep: [MetricPoint]
    /// Bar width: `.day` for a week of nights, `.weekOfYear` / `.month` for longer ranges.
    var bucket: Calendar.Component = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(sleep, id: \.date) { point in
                    BarMark(
                        x: .value("When", point.date, unit: bucket),
                        y: .value("Hours", point.value)
                    )
                    // One colour for every night: a second one for weekends had no key.
                    .foregroundStyle(DS.Palette.Feature.wake)
                    .cornerRadius(4)
                }
                // The average is a dashed line across the bars, labelled where it ends.
                if let avg = average {
                    RuleMark(y: .value("Average", avg))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("avg \(DS.duration(minutes: avg * 60))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxis {
                // Two labels, trailing: nothing and the longest night, on light lines.
                AxisMarks(position: .trailing, values: [0, yTop]) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(DS.Tint.fill))
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartYScale(domain: 0...yTop)
            .chartXAxis { AxisMarks { AxisValueLabel(format: xAxisFormat) } }
            .frame(height: 140)
            if !weekendVsWeekday.isEmpty {
                Text(weekendVsWeekday).font(.caption).foregroundStyle(.secondary)
            }
        }
        .groupedCard()
    }

    private func isWeekend(_ d: Date) -> Bool { Calendar.current.isDateInWeekend(d) }

    private var xAxisFormat: Date.FormatStyle {
        switch bucket {
        case .day:          return .dateTime.weekday(.narrow)
        case .weekOfYear:   return .dateTime.month(.abbreviated).day()
        default:            return .dateTime.month(.narrow)
        }
    }

    private var average: Double? {
        let v = sleep.map(\.value)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    /// The top of the scale: the longest night, rounded up to a whole hour.
    private var yTop: Double {
        max(1, (sleep.map(\.value).max() ?? 8).rounded(.up))
    }

    /// Only meaningful when each bar is a night; over weeks or months the split says nothing.
    var weekendVsWeekday: String {
        guard bucket == .day else { return "" }
        let wknd = sleep.filter { isWeekend($0.date) }.map(\.value)
        let week = sleep.filter { !isWeekend($0.date) }.map(\.value)
        guard !wknd.isEmpty, !week.isEmpty else { return "" }
        let diff = (wknd.reduce(0, +) / Double(wknd.count)) - (week.reduce(0, +) / Double(week.count))
        let mins = Int(abs(diff) * 60)
        // Said only when there's a real difference; a steady week needs no sentence.
        if mins < 20 { return "" }
        let amount = DS.duration(minutes: Double(mins))
        return diff > 0 ? "~\(amount) more on weekends — weekday debt."
                        : "~\(amount) less on weekends."
    }
}
