import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Main-actor boundary only. The resulting request contains resolved artwork inputs;
/// the rasterizer never receives SwiftUI views, provider models or environment values.
@MainActor
enum CalendarNativeEventAdapter {
    static func request(paint: CalendarEventPaint, size: CGSize, paintHeight: CGFloat,
                        desktop: Bool, showsIcon: Bool, environment: EnvironmentValues)
        -> CalendarNativeEventRaster.Request {
        func color(_ value: Color) -> CGColor {
            let resolved = value.resolve(in: environment)
            return CGColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
        }
        let tint = color(paint.tint), secondary = color(.secondary)
        let redacted = !environment.redactionReasons.isEmpty
        func font(_ size: CGFloat, bold: Bool = false, digits: Bool = false, rounded: Bool = false) -> CTFont {
            #if os(macOS)
            let base = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            return (rounded ? NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)
                ?? base.fontDescriptor, size: size) ?? base : base) as CTFont
            #else
            let base = digits ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                : UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            return (rounded ? UIFont(descriptor: base.fontDescriptor.withDesign(.rounded)
                ?? base.fontDescriptor, size: size) : base) as CTFont
            #endif
        }
        func text(_ value: String, size: CGFloat, bold: Bool = false, digits: Bool = false,
                  color: CGColor, lines: Int = 1, rounded: Bool = false) -> CalendarNativeEventRaster.Text {
            var string = redacted ? "" : value
            switch environment.textCase {
            case .uppercase: string = string.uppercased(with: environment.locale)
            case .lowercase: string = string.lowercased(with: environment.locale)
            default: break
            }
            return .init(value: NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold, digits: digits, rounded: rounded),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]), maximumLines: lines)
        }
        func symbol(_ name: String, tint: CGColor) -> CGImage? {
            guard !redacted else { return nil }
            #if os(macOS)
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(.init(hierarchicalColor: NSColor(cgColor: tint) ?? .labelColor))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #else
            let config = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            return UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(UIColor(cgColor: tint), renderingMode: .alwaysOriginal).cgImage
            #endif
        }
        let twoLine = desktop ? paintHeight >= DS.Event.twoLineMinHeight : paintHeight >= 40
        let titleLines = desktop ? (twoLine ? max(1, Int(min(128, (paintHeight - 20) / 13))) : 1)
            : (paintHeight >= 76 ? 3 : (paintHeight >= 40 ? 2 : 1))
        var title = text(paint.title, size: !desktop && paintHeight < 20 ? 9 : 11,
            bold: true, color: desktop ? tint : color(.primary), lines: titleLines)
        if desktop && !twoLine {
            let combined = NSMutableAttributedString(attributedString: title.value)
            combined.append(text("  " + paint.startText, size: 10, digits: true,
                color: tint.copy(alpha: tint.alpha * 0.75)!).value)
            title = .init(value: combined, maximumLines: 1)
        } else if !desktop && !twoLine && paint.isMoment && paint.hasScheduledTime {
            // An instant has no second line. Keep its time visible before a long title truncates.
            let combined = NSMutableAttributedString(attributedString: text(paint.startText + "  ",
                size: paintHeight < 20 ? 9 : 10, digits: true, color: secondary).value)
            combined.append(title.value)
            title = .init(value: combined, maximumLines: 1)
        }
        var subtitle: CalendarNativeEventRaster.Text?
        if let caption = paint.returnCaption, !desktop || twoLine {
            subtitle = text(caption, size: desktop ? 10 : 9, bold: true, color: color(DS.Palette.travel), rounded: !desktop)
        } else if twoLine {
            subtitle = text(paint.timeRange, size: 10, digits: true,
                color: desktop ? tint.copy(alpha: tint.alpha * 0.8)! : secondary)
        }
        var iconName: String?
        if paint.isTask { iconName = paint.completed ? "checkmark.circle.fill" : "circle" }
        else if desktop || !paint.isEvent {
            if paint.completed { iconName = "checkmark.circle.fill" }
            else if paint.skipped { iconName = "xmark.circle" }
            else if showsIcon || !desktop { iconName = paint.icon }
        }
        return .init(size: size, scale: environment.displayScale, tint: tint,
            ribbons: paint.ribbons.map(color), fillOpacity: paint.fillOpacity,
            opacity: desktop ? (paint.completed ? 0.55 : (paint.skipped ? 0.4 : 1))
                : (paint.completed || paint.skipped ? 0.55 : 1),
            title: title, subtitle: subtitle,
            location: !desktop && paintHeight >= 64
                ? paint.location.map { text($0, size: 9, color: secondary, rounded: true) } : nil,
            icon: iconName.flatMap { symbol($0, tint: tint) },
            warning: paint.othersDeclined ? symbol("exclamationmark.triangle.fill", tint: color(DS.Palette.accent)) : nil,
            desktop: desktop, rightToLeft: environment.layoutDirection == .rightToLeft,
            free: paint.showsAsFree, tentative: paint.tentative, needsAction: paint.needsAction,
            textVisible: desktop || paintHeight >= 9, centerSingleLine: desktop && !twoLine,
            strikeThrough: paint.completed || paint.skipped, redacted: redacted,
            subtitleIcon: paint.returnCaption != nil && (!desktop || twoLine)
                ? symbol("house", tint: color(DS.Palette.travel)) : nil)
    }
}
