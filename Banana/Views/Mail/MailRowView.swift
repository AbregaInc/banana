#if !BANANA_PUBLIC
import SwiftUI

/// Which row a list draws: one line each where the list column has room for columns, three lines
/// where it has not (MAIL-UX 6.1.2, 6.1.3). Chosen by the width of the list column, never the
/// device: a list beside a reading pane is three lines on a Mac as on a phone.
enum MailRowStyle: Equatable {
    case oneLine, threeLine

    init(_ arrangement: MailArrangement) {
        self = arrangement.usesOneLineRows ? .oneLine : .threeLine
    }

    /// Both are fixed: the list host measures nothing (prototype P1). On iPhone and iPad they
    /// grow with the text size (MAIL-UX 6.1.3), by the same factor as the text style two of a
    /// three-line row's lines are set in — so at the default size they are the tokens exactly,
    /// and at an accessibility size the lines are not drawn over the next row.
    var height: CGFloat {
        switch self {
        case .oneLine: Self.scaled(DS.Mail.oneLineRow, with: .body)
        case .threeLine: Self.scaled(DS.Mail.threeLineRow, with: .subheadline)
        }
    }

    #if os(iOS)
    /// The rule is `MailRowHeight`'s; this reads the two line heights from the system's fonts.
    private static func scaled(_ base: CGFloat, with style: UIFont.TextStyle) -> CGFloat {
        let standard = UIFont.preferredFont(forTextStyle: style,
                                            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
        let current = UIFont.preferredFont(forTextStyle: style).lineHeight
        return MailRowHeight.scaled(base, standard: standard, current: current)
    }
    #else
    /// The Mac has no Dynamic Type: the token.
    private static func scaled(_ base: CGFloat, with style: NSFont.TextStyle) -> CGFloat { base }
    #endif
}

/// One conversation's row: who, how many, what about, what it says, when, and the marks.
///
/// `Equatable`, and applied with `.equatable()` by both hosts, so a row handed an equal value is
/// not drawn again. The cursor is not an input of this view: `MailRowCursor` draws it by observing
/// the row's own mark, so a held `J` re-evaluates two small leaves and nothing else.
struct MailRowView: View, Equatable {
    let id: MailConversationID
    let display: MailRowDisplay
    let style: MailRowStyle
    /// `style.height` at the text size in force, read once by the host and handed in: reading it
    /// is two font lookups and a trait collection, and a cell is configured on the scroll path.
    /// Part of what makes two rows equal, so a change of text size draws the rows again.
    let height: CGFloat
    let mark: MailRowMark

    static func == (a: MailRowView, b: MailRowView) -> Bool {
        a.id == b.id && a.display == b.display && a.style == b.style && a.height == b.height && a.mark === b.mark
    }

    var body: some View {
        Group {
            switch style {
            case .oneLine: MailOneLineRow(display: display)
            case .threeLine: MailThreeLineRow(display: display)
            }
        }
        .frame(height: height, alignment: .top)
        .background(MailRowCursor(mark: mark))
        .overlay(alignment: .bottom) {
            DS.Palette.separator.frame(height: 1).padding(.leading, DS.Mail.gutter)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(MailID.row(id.thread))
    }
}

/// The cursor, drawn by a leaf that watches one row's mark and nothing else.
struct MailRowCursor: View {
    @ObservedObject var mark: MailRowMark

    var body: some View {
        if mark.hasCursor {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Palette.selection)
                .padding(.horizontal, DS.Space.xs)
        }
    }
}

// MARK: - The two arrangements

private struct MailOneLineRow: View {
    let display: MailRowDisplay

    var body: some View {
        HStack(spacing: DS.Space.s) {
            MailUnreadDot(isUnread: display.isUnread)
            HStack(spacing: DS.Space.xs) {
                Text(display.who)
                    .fontWeight(display.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                if let count = display.count {
                    Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: DS.Mail.senderColumn)
            // The subject, then the snippet in secondary: one run that truncates at its tail.
            Text("\(subject)  \(MailRowSnippet.text(display).foregroundStyle(.secondary))")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            MailGlyphs(display: display)
            Text(display.date)
                .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: DS.Mail.dateColumn, alignment: .trailing)
        }
        .padding(.trailing, DS.Space.m)
        .frame(maxHeight: .infinity)
    }

    private var subject: Text {
        Text(display.subject)
            .fontWeight(display.isUnread ? .semibold : .regular)
            .foregroundStyle(display.subjectIsPlaceholder ? .secondary : .primary)
    }
}

private struct MailThreeLineRow: View {
    let display: MailRowDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MailUnreadDot(isUnread: display.isUnread)
                .frame(height: DS.Mail.glyphSlot)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(display.who)
                        .font(.callout.weight(display.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if let count = display.count {
                        Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.s)
                    Text(display.date).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: DS.Space.s) {
                    Text(display.subject)
                        .font(.subheadline.weight(display.isUnread ? .medium : .regular))
                        .foregroundStyle(display.subjectIsPlaceholder ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    MailGlyphs(display: display)
                }
                MailRowSnippet.text(display)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.trailing, DS.Space.l)
        }
        .padding(.top, DS.Space.s)
    }
}

/// What a row says where the snippet would be: the snippet, or "Draft" and what the draft begins
/// with, or "Sending…" for a message of his that is inside its undo hold (MAIL-UX 7.6).
private enum MailRowSnippet {
    static func text(_ display: MailRowDisplay) -> Text {
        if let draft = display.draft {
            let word = Text("Draft").foregroundStyle(DS.Palette.danger)
            return draft.isEmpty ? word : Text("\(word) \u{00B7} \(draft)")
        }
        if let scheduled = display.scheduled {
            return Text(scheduled).foregroundStyle(display.isLate ? DS.Palette.warning : DS.Palette.info)
        }
        if display.isSending {
            return Text("Sending\u{2026}")
        }
        if display.isKeptAfterRemoval { return Text("No longer in Gmail · Kept on this device") }
        return Text(display.snippet)
    }
}

/// The unread dot: `info`, not the accent, which means now and selected. With the semibold name,
/// two signals, neither colour alone.
private struct MailUnreadDot: View {
    let isUnread: Bool

    var body: some View {
        ZStack {
            if isUnread {
                Circle().fill(DS.Palette.info).frame(width: DS.Row.statusDot, height: DS.Row.statusDot)
            }
        }
        .frame(width: DS.Mail.gutter)
    }
}

/// The three marks, in their fixed order and always three slots wide, so the date never moves:
/// attachment, invitation, star.
private struct MailGlyphs: View {
    let display: MailRowDisplay

    var body: some View {
        HStack(spacing: 0) {
            slot("paperclip", on: display.hasAttachment)
            slot("calendar", on: display.isInvitation)
            slot("star.fill", on: display.isStarred, tint: DS.Palette.accent)
        }
    }

    private func slot(_ symbol: String, on: Bool, tint: Color = .secondary) -> some View {
        ZStack {
            if on { Image(systemName: symbol).font(.footnote).foregroundStyle(tint) }
        }
        .frame(width: DS.Mail.glyphSlot)
    }
}

#endif
