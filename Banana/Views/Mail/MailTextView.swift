#if !BANANA_PUBLIC
import SwiftUI

/// A message's text, drawn natively from its meaning (`MailText`): paragraphs, quotes, lists,
/// headings, preformatted lines and rules, with system link handling.
struct MailTextView: View {
    let text: MailText
    /// The blocks already styled off the main thread (`MailReaderModel.styled`); styled here
    /// only when absent.
    var styled: [AttributedString]? = nil

    var body: some View {
        let ready = styled?.count == text.blocks.count ? styled : nil
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(text.blocks.enumerated()), id: \.offset) { index, block in
                MailBlockView(block: block, styled: ready?[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailBlockView: View {
    let block: MailTextBlock
    let styled: AttributedString?

    private var runs: AttributedString { styled ?? MailAttributedText.make(block.runs) }

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(runs).font(.body)
        case .quote(let depth):
            HStack(alignment: .top, spacing: DS.Space.s) {
                // One bar for each level of quoting, to five: deeper than that is just darker.
                ForEach(0..<min(max(depth, 1), 5), id: \.self) { _ in
                    DS.Palette.gridHour.frame(width: DS.Space.hair)
                }
                Text(runs).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .item(let ordered, let depth, let number):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(ordered ? "\(number ?? 1)." : "\u{2022}").foregroundStyle(.secondary)
                Text(runs).font(.body)
            }
            .padding(.leading, DS.Space.l * CGFloat(depth))
        case .heading:
            Text(runs).font(.headline)
        case .preformatted:
            Text(runs).font(.system(.callout, design: .monospaced))
        case .rule:
            Divider()
        }
    }
}

#endif
