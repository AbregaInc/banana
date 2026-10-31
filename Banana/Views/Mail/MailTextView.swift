#if !BANANA_PUBLIC
import SwiftUI

/// A message's text, drawn natively from its meaning (`MailText`): paragraphs, quotes, lists,
/// headings, preformatted lines and rules. No web view, no remote picture, and no link that
/// opens: the slice shows plain-text bodies and nothing else (MAIL-UX 6.2).
struct MailTextView: View {
    let text: MailText

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
                MailBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailBlockView: View {
    let block: MailTextBlock

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(MailAttributedText.make(block.runs)).font(.body)
        case .quote(let depth):
            HStack(alignment: .top, spacing: DS.Space.s) {
                // One bar for each level of quoting, to five: deeper than that is just darker.
                ForEach(0..<min(max(depth, 1), 5), id: \.self) { _ in
                    DS.Palette.gridHour.frame(width: DS.Space.hair)
                }
                Text(MailAttributedText.make(block.runs)).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .item(let ordered, let depth, let number):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(ordered ? "\(number ?? 1)." : "\u{2022}").foregroundStyle(.secondary)
                Text(MailAttributedText.make(block.runs)).font(.body)
            }
            .padding(.leading, DS.Space.l * CGFloat(depth))
        case .heading:
            Text(MailAttributedText.make(block.runs)).font(.headline)
        case .preformatted:
            Text(MailAttributedText.make(block.runs)).font(.system(.callout, design: .monospaced))
        case .rule:
            Divider()
        }
    }
}

#endif
