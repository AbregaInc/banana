import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Banana's design system: the only place a spacing, radius, type size or calendar tint is
/// decided. Views name the ROLE ("an event title", "a gutter label"), never a number, so the same
/// kind of thing looks the same on every screen and a change lands everywhere at once.
///
/// Before this existed the calendar views used ~20 padding values (2, 2.5, 3, 5, 7, 11…), 15
/// corner radii and hard-coded 8–20 pt font sizes — each individually reasonable, together the
/// reason nothing quite lined up. `WorkoutDesign.swift` is the Workouts-specific layer on top.
enum DS {

    /// A 4-pt scale. Anything off it is a bug.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Continuous-corner radii, by what the shape is. Nested shapes step down one size so their
    /// curves stay concentric.
    enum Radius {
        static let block: CGFloat = 5       // event blocks, grid chips
        static let chip: CGFloat = 6        // tags, key caps, small pills
        static let control: CGFloat = 8     // buttons, fields, list selection
        static let card: CGFloat = 12       // cards, popovers, toasts
        static let panel: CGFloat = 16      // sheets, palettes, widgets' inner cards
    }

    /// Artwork (podcast covers, thumbnails): the corner follows the size tier rather than a
    /// fixed fraction — 18% of a 180 pt cover was a 32 pt radius, rounder than anything else.
    static func artworkRadius(for size: CGFloat) -> CGFloat {
        switch size {
        case ..<48: return Radius.chip
        case ..<80: return Radius.control
        case ..<160: return Radius.card
        default: return Radius.panel
        }
    }

    /// Type roles. Sizes are fixed rather than Dynamic Type on the calendar grid, where rows are
    /// laid out on a time ruler; everywhere else use the text styles below.
    enum Typeface {
        /// Period title in the planner header: "September 21 – 27".
        static let periodTitle = Font.system(size: 17, weight: .semibold)
        /// Small uppercase label above or beside content ("NO TIME", "TOMORROW").
        static let eyebrow = Font.system(size: 10, weight: .semibold)
        static let eyebrowTracking: CGFloat = 0.6
        /// Day column header: weekday and date on one line.
        static let dayHeader = Font.system(size: 12, weight: .medium)
        static let dayHeaderToday = Font.system(size: 12, weight: .semibold)
        /// Hour labels in the time gutter.
        static let gutter = Font.system(size: 10, weight: .medium).monospacedDigit()
        /// Event block title and its time line.
        static let eventTitle = Font.system(size: 11, weight: .semibold)
        static let eventMeta = Font.system(size: 10, weight: .regular).monospacedDigit()
        /// Keyboard key caps.
        static let keyCap = Font.system(size: 11, weight: .medium)
    }

    /// Every colour Banana uses, by role. Never write `.orange` or `.green` in a view: pick the
    /// role, so one meaning is always one colour ("done" is `success` everywhere, not green on
    /// one screen and mint on the next) and the accent is defined exactly once.
    enum Palette {
        /// The system's accent: the colour picked in a Mac's System Settings, the system's own
        /// blue on a phone or iPad. There is no AccentColor asset, so nothing overrides it.
        static let accent = Color.accentColor
        /// The current-time line and label.
        static let now = accent

        // Semantic roles.
        static let success = Color.green        // done, accepted, connected, healthy
        static let danger = Color.red           // delete, declined, failed
        /// Needs attention, not an error. An amber that reads as words on a light ground (the
        /// system's yellow is 1.5:1 there); the system's yellow on a dark one.
        static let warning: Color = {
            #if os(iOS)
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.69, green: 0.42, blue: 0, alpha: 1) })
            #elseif os(macOS)
            Color(nsColor: NSColor(name: nil) {
                $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : NSColor(red: 0.69, green: 0.42, blue: 0, alpha: 1)
            })
            #else
            Color.yellow
            #endif
        }()
        static let info = Color.blue            // links, neutral status

        // Kinds of thing on the timeline.
        static let task = Color.green           // reminders and their checkmarks
        static let travel = Color.blue          // leave-by and travel-home legs

        /// Macronutrients — their own hues, one per macro on every surface, chosen to collide
        /// with no role above (carbs used to be the brand orange and fat the danger red).
        /// Feature identity on settings rows' icon tiles — one colour per feature, the way the
        /// system's own Settings does it. Identity only, never a status.
        enum Feature {
            static let calendar = Color.red
            static let booking = Color.teal
            static let travel = Palette.travel
            static let wake = Color.indigo
            static let podcasts = Color.purple
            static let workouts = Color.green
            static let food = Color.orange
            static let icloud = Color.cyan
            static let system = Color.gray
            /// Mail's settings tile: a manila envelope. A hue nothing else in the system uses.
            static let mail = Color.brown
        }

        /// Effort and heart-rate zones, easy → max. One ramp for charts, routes and bars; red at
        /// the top, not the accent — the accent never judges effort.
        static let zones: [Color] = [.blue, .cyan, .green, .yellow, .red]

        enum Macro {
            static let protein = Color.pink
            static let carbs = Color.teal
            static let fat = Color.purple
        }

        /// Banana's own colours, from the brand board: the fan behind the mark and the blocks of
        /// the website. For the product's four areas (Plan, Listen, Food, Move) and for moments
        /// when Banana is introducing itself. Never a status, and never the colour of text on a
        /// plain background: the yellow and the orange don't carry there.
        enum Brand {
            static let yellow = Color(red: 1.0, green: 0.82, blue: 0.149)      // #FFD126
            static let orange = Color(red: 1.0, green: 0.545, blue: 0.173)     // #FF8B2C
            static let coral = Color(red: 1.0, green: 0.349, blue: 0.396)      // #FF5965
            static let green = Color(red: 0.31, green: 0.78, blue: 0.404)      // #4FC767
            static let purple = Color(red: 0.408, green: 0.31, blue: 0.902)    // #684FE6
            static let blue = Color(red: 0.204, green: 0.498, blue: 0.91)      // #347FE8
            static let ink = Color(red: 0.09, green: 0.09, blue: 0.075)        // #171713
            static let ivory = Color(red: 1.0, green: 0.973, blue: 0.918)      // #FFF8EA
        }

        /// A label or glyph on the accent: white, as on the system's own prominent button.
        static let onAccent = Color.white

        // Neutrals, drawn over the system backgrounds.
        static let separator = Color.primary.opacity(0.08)
        static let gridHour = Color.primary.opacity(0.09)
        static let gridHalfHour = Color.primary.opacity(0.035)
        static let selection = Color.primary.opacity(0.08)
        static let todayWash = accent.opacity(Tint.wash)
    }

    /// The only opacities a tint of a colour may use — a wash behind today's column, a subtle
    /// hover, a soft chip, an event fill, a strong highlight. There were ~20 ad hoc values.
    enum Tint {
        static let wash: Double = 0.04
        static let subtle: Double = 0.08
        static let soft: Double = 0.14
        static let fill: Double = 0.2
        static let strong: Double = 0.35
    }

    /// How an event block is filled and edged.
    enum Event {
        /// Only where a colour must sit in a narrow line of its own (a calendar's swatch in a
        /// list of calendars). Never on a card, row or block (DESIGN-SYSTEM.md, the standard).
        static let spineWidth: CGFloat = 3
        /// One calendar's dot, on an event that is on several.
        static let calendarDot: CGFloat = 5
        static let fill: Double = Tint.fill
        /// Free, and invitations not yet answered: present, not holding the slot.
        static let quietFill: Double = Tint.wash + 0.02
        /// Blocks shorter than this show one line (title, then start time) instead of two.
        static let twoLineMinHeight: CGFloat = 34
        /// The lane width below which blocks drop their kind icon — decided per column, never
        /// per block, so the same kind of event looks the same across a week.
        static let iconMinColumnWidth: CGFloat = 132
    }

    /// Row anatomy shared by every list, so a settings row, an account card and a workout row
    /// are built from the same few sizes (DESIGN-SYSTEM.md, "Rows").
    enum Row {
        /// Tap target; a row is never shorter.
        static let minHeight: CGFloat = 44
        /// Settings and feature rows: a white symbol on a solid colour tile (`IconTile`).
        static let iconTile: CGFloat = 28
        /// Workout, meal and dose rows: a coloured glyph on a soft tile (`IconTile(style: .soft)`).
        static let glyphTile: CGFloat = 40
        /// A row's picture of what it is: a meal's photo, a workout's route, an episode's cover.
        static let thumbnail: CGFloat = 44
        /// Account cards.
        static let avatar: CGFloat = 32
        static let statusDot: CGFloat = 8
    }

    /// A page that asks for one thing: the first run, a permission's explanation, a confirmation
    /// (DESIGN-SYSTEM.md, "Permissions" and "First run").
    enum Page {
        /// The widest a column of reading gets. On an iPad or a Mac the content sits in the
        /// middle at this width: it was the phone's layout stretched to 1,000 points.
        static let readingWidth: CGFloat = 520
        /// The one main button, pinned to the bottom.
        static let buttonHeight: CGFloat = 52
        /// The symbol tile or brand mark that opens the page.
        static let heroTile: CGFloat = 64
        static let brandMark: CGFloat = 88
    }

    /// What stands in for a number that isn't known yet or doesn't apply. Never "0", which reads
    /// as data, and never an empty space, which makes the layout jump when the value arrives.
    static let placeholder = "\u{2014}"

    /// "6h 50m", "7h", "45m": the one way a span of hours and minutes is written (sleep, a
    /// review's totals, a workout in a list). No zero padding, no spaces inside a part.
    static func duration(minutes: Double) -> String {
        let whole = max(0, Int(minutes.rounded()))
        guard whole >= 60 else { return "\(whole)m" }
        let hours = whole / 60, rest = whole % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Desktop agenda columns keep dates and times beside their titles at every window size.
    enum Agenda {
        static let dateColumn: CGFloat = 112
        static let timeColumn: CGFloat = 116
    }

    /// Mail's own sizes (docs/design/MAIL-UX.md 5.1). Everything else in Mail uses the shared
    /// roles. Only what a screen exists for so far: a size is added with the view that draws it.
    enum Mail {
        /// The leading lane of a row: the unread dot.
        static let gutter: CGFloat = 20
        /// The cursor's mark at the leading edge of its row: the event spine's width.
        static let cursorSpine: CGFloat = Event.spineWidth
        /// A one-line row. Where the pointer is a mouse it is the panel row; where it can be a
        /// finger it is the tap target.
        #if os(macOS)
        static let oneLineRow: CGFloat = 32
        #else
        static let oneLineRow: CGFloat = Row.minHeight
        #endif
        /// The three-line row of a narrow list: names, subject, snippet. Fixed, because the list
        /// host measures nothing (prototype P1); it does not grow with Dynamic Type yet.
        static let threeLineRow: CGFloat = 76
        /// Columns of a one-line row.
        static let senderColumn: CGFloat = 176
        static let dateColumn: CGFloat = 72
        static let glyphSlot: CGFloat = 20
        /// The list's and the conversation's header: the planner header's height.
        static let header: CGFloat = 44
        /// The widest a conversation's column gets.
        static let readingMeasure: CGFloat = 680
        /// The composer's body is at least this tall, and grows with its text to the larger.
        static let composerBodyMin: CGFloat = 120
        static let composerBodyMax: CGFloat = 320
        /// The words in front of a recipient or subject row: To, Cc, Subject.
        static let composerLabel: CGFloat = 56
        /// A composer in a sheet, where a sheet has a size of its own (the Mac).
        static let composerSheetWidth: CGFloat = 520
        static let composerSheetHeight: CGFloat = 560
        /// The narrowest the To field's typing gets before it wraps to a line of its own.
        static let composerTyping: CGFloat = 120
        /// The narrowest a button of a message's own actions gets, wide enough for "Keep as a draft".
        static let actionButton: CGFloat = 120
    }
}

/// "9–10:30 AM", "11:30 AM–12:15 PM", "9 AM": a time range as a person writes it. The day part
/// is said once when both ends share it, and ":00" is dropped. 24-hour locales get "09:00–10:30".
enum TimeRangeText {
    static func compact(_ start: Date, _ end: Date?, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        guard let end, end > start else { return time(start, calendar: calendar, locale: locale) }
        guard uses12Hour(locale) else {
            return "\(time(start, calendar: calendar, locale: locale))–\(time(end, calendar: calendar, locale: locale))"
        }
        let sameHalf = calendar.component(.hour, from: start) / 12 == calendar.component(.hour, from: end) / 12
            && calendar.isDate(start, inSameDayAs: end)
        if sameHalf {
            return "\(clock(start, calendar: calendar))–\(time(end, calendar: calendar, locale: locale))"
        }
        return "\(time(start, calendar: calendar, locale: locale))–\(time(end, calendar: calendar, locale: locale))"
    }

    /// One time: "9 AM", "9:30 AM", or "09:30".
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard uses12Hour(locale) else {
            let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
            return String(format: "%02d:%02d", h, m)
        }
        let symbol = calendar.component(.hour, from: date) < 12 ? amSymbol(locale) : pmSymbol(locale)
        return "\(clock(date, calendar: calendar)) \(symbol)"
    }

    /// A clock reading with no day part, for tight spaces (the now-label, a round widget):
    /// "2:43" — or "14:43" where the locale uses a 24-hour clock. Never "02:43".
    static func clockOnly(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard uses12Hour(locale) else { return time(date, calendar: calendar, locale: locale) }
        let hour24 = calendar.component(.hour, from: date)
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d", hour, calendar.component(.minute, from: date))
    }

    /// "9" or "9:30" — the 12-hour clock without the day part.
    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = calendar.component(.minute, from: date)
        return minute == 0 ? "\(hour)" : String(format: "%d:%02d", hour, minute)
    }

    // These conventions are locale-wide, not event-specific. Creating a formatter and
    // resolving its ICU symbols for every label dominated dense calendar paging samples.
    private final class Convention: NSObject {
        let uses12Hour: Bool
        let am: String
        let pm: String
        init(locale: Locale) {
            uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
            let formatter = DateFormatter()
            formatter.locale = locale
            am = formatter.amSymbol ?? "AM"
            pm = formatter.pmSymbol ?? "PM"
        }
    }

    private static let conventions: NSCache<NSLocale, Convention> = {
        let cache = NSCache<NSLocale, Convention>()
        cache.countLimit = 8
        // The cache and observer live for the process. User 12/24-hour and locale changes
        // invalidate current-locale preferences, even when the locale identifier is unchanged.
        _ = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                    object: nil, queue: nil) { _ in
            cache.removeAllObjects()
        }
        return cache
    }()

    private static func convention(_ locale: Locale) -> Convention {
        let key = locale as NSLocale
        if let cached = conventions.object(forKey: key) { return cached }
        let value = Convention(locale: locale)
        conventions.setObject(value, forKey: key)
        return value
    }

    static func uses12Hour(_ locale: Locale) -> Bool { convention(locale).uses12Hour }
    private static func amSymbol(_ locale: Locale) -> String { convention(locale).am }
    private static func pmSymbol(_ locale: Locale) -> String { convention(locale).pm }
}

/// A keyboard key, drawn as a key cap: one cap per key, as on the keyboard itself.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(DS.Typeface.keyCap)
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, key.count > 1 ? DS.Space.xs : 0)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }
}

/// A shortcut as a row of key caps: "⌃⌘J" → ⌃ ⌘ J. Words ("Esc", "then") stay whole.
struct KeyCombo: View {
    let combo: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.keys(combo).enumerated()), id: \.offset) { _, key in
                if key == "then" || key == "/" || key == "–" {
                    Text(key).font(.caption).foregroundStyle(.tertiary)
                } else {
                    KeyCap(key: key)
                }
            }
        }
    }

    static func keys(_ combo: String) -> [String] {
        combo.split(separator: " ").flatMap { part -> [String] in
            let word = String(part)
            if word.count > 1, word.allSatisfy({ $0.isLetter }) { return [word] }   // "Esc", "then"
            return word.map { String($0) }
        }
    }
}

/// A number with its unit and label — one shape for every figure in the app (workout stats,
/// nutrition totals, health metrics), so the same kind of fact reads the same everywhere.
///
/// Label above in the caption style (sentence case); value in tabular digits so it doesn't
/// jitter as it changes; unit at ~0.58× in secondary, on the value's baseline. `footnote` is the
/// comparison slot — a goal ("of 2,041"), an average ("avg 143 bpm"), a change ("↑ 4% vs last
/// month"). A nil value shows `DS.placeholder`, so a grid of stats never reflows while data loads.
struct StatValue: View {
    enum Size {
        /// Inside a list row.
        case row
        /// A stat grid or strip.
        case tile
        /// The one number a screen is about.
        case hero
    }

    let label: String?
    let value: String?
    var unit: String? = nil
    var footnote: String? = nil
    var size: Size = .tile
    var alignment: HorizontalAlignment = .leading

    @ScaledMetric(relativeTo: .body) private var rowSize: CGFloat = 17
    @ScaledMetric(relativeTo: .title2) private var tileSize: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44

    private var valueSize: CGFloat {
        switch size {
        case .row: rowSize
        case .tile: tileSize
        case .hero: heroSize
        }
    }

    /// "150 W" → ("150", "W"), "6:12 /km" → ("6:12", "/km"), "1:02:03" → ("1:02:03", nil): the
    /// unit is a trailing word with a letter in it, so formatters that already append one feed
    /// straight in. "—" and "–" mean "no value".
    static func split(_ text: String) -> (value: String?, unit: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == DS.placeholder || trimmed == "\u{2013}" || trimmed == "-" {
            return (nil, nil)
        }
        guard let space = trimmed.lastIndex(of: " ") else { return (trimmed, nil) }
        let unit = String(trimmed[trimmed.index(after: space)...])
        let value = String(trimmed[..<space]).trimmingCharacters(in: .whitespaces)
        guard unit.contains(where: \.isLetter), !value.isEmpty,
              value.contains(where: \.isNumber) else { return (trimmed, nil) }
        return (value, unit)
    }

    /// SF Rounded is reserved for large numerals, so only the hero size uses it.
    private var valueFont: Font {
        switch size {
        case .row: .system(size: valueSize, weight: .medium).monospacedDigit()
        case .tile: .system(size: valueSize, weight: .semibold).monospacedDigit()
        case .hero: .system(size: valueSize, weight: .bold, design: .rounded).monospacedDigit()
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: DS.Space.hair) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: size == .hero ? DS.Space.xs : DS.Space.hair) {
                Text(value ?? DS.placeholder)
                    .font(valueFont)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                if let unit, value != nil {
                    Text(unit)
                        .font(.system(size: (valueSize * 0.58).rounded(), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if let footnote {
                Text(footnote)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A group of rows or a tile on a plain page. The phone's grouped background reads against its
/// page; on the Mac that colour is white on a white window, so there it's a wash of the text
/// colour with a hairline edge instead.
struct DSCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        #if os(macOS)
        content
            .background(Color.primary.opacity(DS.Tint.wash), in: shape)
            .overlay(shape.strokeBorder(DS.Palette.separator))
        #else
        content.background(Color(.secondarySystemGroupedBackground), in: shape)
        #endif
    }
}

extension View {
    func dsCard() -> some View { modifier(DSCard()) }
}

/// A symbol on a small rounded tile — the leading element of a settings row (`.solid`) or of a
/// workout / meal / dose row (`.soft`).
struct IconTile: View {
    enum Style {
        /// White symbol on the colour, like Settings.
        case solid
        /// Coloured symbol on a `Tint.soft` wash of it.
        case soft
    }

    let systemImage: String
    var tint: Color = DS.Palette.accent
    var style: Style = .solid
    var size: CGFloat = DS.Row.iconTile
    /// The symbol on a solid tile, when white would not read: ink on the brand's yellow.
    var glyph: Color?

    private var radius: CGFloat {
        if size <= DS.Row.iconTile { return DS.Radius.chip }
        return size <= DS.Row.minHeight ? DS.Radius.control : DS.Radius.panel
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(style == .solid ? (glyph ?? .white) : tint)
            .frame(width: size, height: size)
            .background(style == .solid ? tint : tint.opacity(DS.Tint.soft), in: shape)
            .accessibilityHidden(true)
    }
}

/// Whether a connection, sync or permission is working — the 8-pt dot on account cards and
/// status rows. Always paired with a word ("Live", "Syncing", "Sign in again"): the word carries
/// the meaning, the colour only supports it.
enum ConnectionStatus: Equatable {
    case ok, working, attention, off

    var color: Color {
        switch self {
        case .ok: DS.Palette.success
        case .working: DS.Palette.accent      // Banana is doing something right now
        case .attention: DS.Palette.danger
        case .off: .secondary
        }
    }
}

struct StatusDot: View {
    let status: ConnectionStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: DS.Row.statusDot, height: DS.Row.statusDot)
            .accessibilityHidden(true)
    }
}

/// Calendar colours, evened out.
///
/// Google's palette runs from pastel to neon, and dark mode makes the spread worse: a
/// "Banana" yellow glares while a "Graphite" all but vanishes. Each colour keeps its hue — that
/// is what identifies the calendar — but saturation and brightness are pulled into one band per
/// appearance, so a week of mixed calendars reads as one surface.
enum CalendarColor {
    struct HSB: Equatable {
        var hue: Double, saturation: Double, brightness: Double
    }

    static func hsb(hex: String?) -> HSB? {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return HSB(hue: hue, saturation: maxC == 0 ? 0 : delta / maxC, brightness: maxC)
    }

    /// The evened-out colour for one appearance. Greys stay grey.
    static func normalized(_ c: HSB, dark: Bool) -> HSB {
        guard c.saturation > 0.08 else {
            return HSB(hue: c.hue, saturation: c.saturation, brightness: dark ? 0.72 : 0.5)
        }
        return dark
            ? HSB(hue: c.hue, saturation: min(max(c.saturation, 0.4), 0.62), brightness: 0.9)
            : HSB(hue: c.hue, saturation: min(max(c.saturation, 0.5), 0.8), brightness: min(max(c.brightness, 0.55), 0.72))
    }

    /// A colour that re-resolves when the appearance changes.
    static func color(hex: String?) -> Color? {
        guard let source = hsb(hex: hex) else { return nil }
        let light = normalized(source, dark: false), dark = normalized(source, dark: true)
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(hue: c.hue, saturation: c.saturation, brightness: c.brightness, alpha: 1)
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(hue: c.hue, saturation: c.saturation, brightness: c.brightness, alpha: 1)
        })
        #else
        return Color(hue: dark.hue, saturation: dark.saturation, brightness: dark.brightness)
        #endif
    }
}
