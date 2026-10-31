import Foundation

/// The 5-minute grid every clock-time entry point in the app is meant to land on — the wheel
/// below, plus any spot (new-event defaults, the week grid's tap/drag-to-create) that computes a
/// time rather than reading one off a control that already enforces the interval. Kept free of
/// UIKit/SwiftUI so it builds and is testable on every platform, including macOS.
enum FiveMinuteGrid {
    /// Rounds to the nearest 5-minute mark. Added rather than set, because :58 rounds to 60 —
    /// the next hour, not :55 — and date arithmetic carries that across midnight for free.
    static func snapped(_ date: Date, calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: date)
        let snappedMinute = Int((Double(minute) / 5).rounded()) * 5
        let topOfHour = calendar.date(
            bySettingHour: calendar.component(.hour, from: date),
            minute: 0,
            second: 0,
            of: date) ?? date
        return calendar.date(byAdding: .minute, value: snappedMinute, to: topOfHour) ?? date
    }

    /// What a field that can only step by single minutes (the Mac's) should hold after a
    /// change from `old` to `new`: one press of its minute arrow moves five minutes that way
    /// (the field wraps :59 to :00 inside the hour), and anything else, typed or a change of
    /// hour or day, lands on the nearest mark.
    static func stepped(from old: Date, to new: Date, calendar: Calendar = .current) -> Date {
        let before = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: old)
        let after = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: new)
        let sameHour = before.year == after.year && before.month == after.month
            && before.day == after.day && before.hour == after.hour
        guard sameHour, let was = before.minute, let now = after.minute else { return snapped(new, calendar: calendar) }
        let start = snapped(old, calendar: calendar)
        switch now - was {
        case 1, -59: return calendar.date(byAdding: .minute, value: 5, to: start) ?? new
        case -1, 59: return calendar.date(byAdding: .minute, value: -5, to: start) ?? new
        default: return snapped(new, calendar: calendar)
        }
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI's `DatePicker` cannot step minutes; `UIDatePicker.minuteInterval` can.
struct FiveMinuteTimeWheel: UIViewRepresentable {
    /// What the wheel edits, and how a change reconciles with the rest of the form. Explicit
    /// per call site — an implied default here is exactly how a future caller ends up merging
    /// onto a day nobody chose, or overwriting a day picker fights it for.
    enum Mode {
        /// The wheel edits only hour and minute; the day comes from a separate control
        /// elsewhere in the same form. Every change merges just the clock time onto whatever
        /// day `selection` already holds — the wheel itself never advances or rewinds the day.
        case hourAndMinuteOnly
        /// The wheel is the sole source of truth for `selection`: day, hour and minute are all
        /// edited here and written back verbatim, replacing the bound date outright.
        case fullDate
    }

    @Binding var selection: Date
    let mode: Mode
    /// `.wheels` for a standalone sheet; `.compact` to sit in a Form row next to its label.
    var style: UIDatePickerStyle = .wheels
    /// The earliest and latest that can be picked, when there is a limit.
    var minimum: Date?
    var maximum: Date?

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = mode == .fullDate ? .dateAndTime : .time
        picker.preferredDatePickerStyle = style
        picker.minuteInterval = 5
        // A Form row proposes the full row width; the compact pill has to keep its own.
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        picker.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.parent = self   // never write through a binding from a stale pass
        picker.minimumDate = minimum
        picker.maximumDate = maximum
        picker.date = selection
    }

    /// The wheel keeps the explicit `.frame(height:)` its call site gives it. The compact pill has
    /// to report its own size or SwiftUI collapses it — and `intrinsicContentSize` is not usable
    /// here: before first layout UIKit answers `noIntrinsicMetric` (-1), which SwiftUI renders as
    /// an invisible sliver at the edge of the row. Ask for a fitted size and floor it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context) -> CGSize? {
        guard style == .compact else { return nil }
        let fitted = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: max(fitted.width, 96), height: max(fitted.height, 34))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FiveMinuteTimeWheel
        init(_ parent: FiveMinuteTimeWheel) { self.parent = parent }

        /// Only ever fires from a genuine touch on the wheel (UIKit does not invoke this from
        /// the programmatic `picker.date = selection` above), so an off-grid value passed in
        /// from elsewhere — an event created at 09:07 by another app — is never rewritten just
        /// because the picker appeared. It moves only once the owner turns the wheel, and by
        /// then `sender.date` is already 5-minute aligned courtesy of `minuteInterval`.
        @objc func changed(_ sender: UIDatePicker) {
            switch parent.mode {
            case .fullDate:
                parent.selection = sender.date
            case .hourAndMinuteOnly:
                let calendar = Calendar.current
                let time = calendar.dateComponents([.hour, .minute], from: sender.date)
                if let merged = calendar.date(
                    bySettingHour: time.hour ?? 0,
                    minute: time.minute ?? 0,
                    second: 0,
                    of: parent.selection) {
                    parent.selection = merged
                }
            }
        }
    }
}
#endif
