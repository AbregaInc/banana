#if !BANANA_PUBLIC
import Foundation

/// How tall a list row is at the text size in force (MAIL-UX 6.1.3: a row grows with Dynamic
/// Type). The host draws rows at a fixed height and measures nothing (prototype P1), so the
/// height is a rule, not a measurement: the design token at the default size, and at a larger
/// size the token grown by the same factor as the text style the row's lines are set in, so
/// three lines of a larger size are not drawn over the next row. Pure: the line heights are
/// handed in; the views read them from the system's fonts.
enum MailRowHeight {

    /// `base` is the token; `standard` the line height of the row's text style at the default
    /// size, and `current` its line height now. Never shorter than the token: a smaller text size
    /// keeps the row's 44-point target and its room.
    static func scaled(_ base: CGFloat, standard: CGFloat, current: CGFloat) -> CGFloat {
        guard standard > 0, current > standard else { return base }
        return (base * current / standard).rounded()
    }
}

#endif
