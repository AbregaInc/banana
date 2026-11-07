#if !BANANA_PUBLIC
import SwiftUI

/// A message's text, drawn natively from its meaning (`MailText`): paragraphs, quotes, lists,
/// headings, preformatted lines and rules, with system link handling.
struct MailTextView: View {
    let text: MailText
    /// The prepared body's `quoteStartsAt`: the quoted tail waits behind one button.
    var foldFrom: Int? = nil
    @State private var showsQuote = false

    var body: some View {
        let folded = foldFrom != nil && !showsQuote
        let shown = folded ? Array(text.blocks.prefix(foldFrom ?? 0)) : text.blocks
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                MailBlockView(block: block)
            }
            if folded {
                Button { showsQuote = true } label: {
                    Label("Show quoted text", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("mail.body.quote")
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
        case .fineprint:
            Text(MailAttributedText.make(block.runs)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#endif
