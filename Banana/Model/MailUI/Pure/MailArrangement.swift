#if !BANANA_PUBLIC
import Foundation

/// Which columns Mail shows at the width it has, and which row the list draws. Layout follows
/// room, never the device (docs/design/ADAPTIVE-LAYOUT.md): the same screen on a phone, an iPad
/// and a Mac window, with columns added as the width allows.
///
/// From the left: **control** (where you are in Mail) · **list** · **reading pane** (the
/// conversation under the cursor) · **details** (facts about it, where enrichment will go). As
/// the room shrinks the details go first, then the control column, then the pane, until the
/// list stands alone and opens a conversation full width — the arrangement a phone has.
///
/// ```
/// width       < 600   list alone (a phone, a narrow split)         layoutClass .compact
///             600     list alone, wider
///             660     list · pane
///             828     control · list · pane
///             1076    control · list · pane · details
/// ```
///
/// The widths are the columns' own: a list column of 320 is three-line rows; a pane never
/// narrower than 340; the control column 168; the details 248. They are the rule, so they are
/// here and tested, and the views use them by name.
struct MailArrangement: Equatable, Sendable {

    // MARK: The columns

    static let controlWidth = 168.0
    static let listWidth = 320.0
    static let detailsWidth = 248.0
    static let paneMinWidth = 340.0
    /// The list is one line per row from this width (MAIL-UX 6.1.2); narrower, three lines.
    static let oneLineListMinWidth = 720.0

    // MARK: Where each column appears

    /// The reading pane has room: a list column and a pane.
    static let paneAt = listWidth + paneMinWidth
    /// The control column joins.
    static let controlAt = paneAt + controlWidth
    /// The details column joins: all four.
    static let detailsAt = controlAt + detailsWidth

    var width: Double
    var showsControl: Bool
    var showsPane: Bool
    var showsDetails: Bool
    /// Whether a pane, or details, could be shown at this width whatever he has asked for: the
    /// buttons that toggle them are offered only then.
    var canShowPane: Bool
    var canShowDetails: Bool

    /// `wantsPane` and `wantsDetails` are his two toggles. A pane he has hidden leaves the list
    /// wide, with the control column beside it where there is room; details are about what the
    /// pane shows, so with no pane there are none.
    static func choose(width: Double, wantsPane: Bool = true, wantsDetails: Bool = true) -> MailArrangement {
        let canShowPane = width >= paneAt
        let canShowDetails = width >= detailsAt
        let showsPane = wantsPane && canShowPane
        return MailArrangement(width: width, showsControl: width >= controlAt, showsPane: showsPane,
                               showsDetails: showsPane && wantsDetails && canShowDetails,
                               canShowPane: canShowPane, canShowDetails: canShowDetails)
    }

    /// How wide the list column is, which decides the row it draws: a fixed column beside a
    /// pane, and the rest of the room when it stands alone.
    var listColumnWidth: Double {
        if showsPane { return Self.listWidth }
        return width - (showsControl ? Self.controlWidth : 0)
    }

    var usesOneLineRows: Bool { listColumnWidth >= Self.oneLineListMinWidth }

    /// A tap or click on a row opens the conversation full width only when there is no pane to
    /// show it in; with a pane it places the cursor, and the pane follows.
    var tapOpens: Bool { !showsPane }

    /// A phone's width, and a narrow window's: the list stands alone and a composer is a sheet.
    static let compactBelow = 600.0
    var isCompact: Bool { width < Self.compactBelow }
}

#endif
