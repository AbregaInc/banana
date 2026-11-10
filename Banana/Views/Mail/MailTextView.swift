#if !BANANA_PUBLIC
import SwiftUI

/// A message's text, drawn natively from its meaning (`MailText`): paragraphs, quotes, lists,
/// headings, preformatted lines and rules, with system link handling.
struct MailTextView: View {
    let text: MailText
    /// The blocks already styled off the main thread (`MailReaderModel.styled`); styled here
    /// only when absent.
    var styled: [AttributedString]? = nil
    /// The prepared body's `quoteStartsAt`: the quoted tail waits behind one button.
    var foldFrom: Int? = nil
    @State private var showsQuote = false

    var body: some View {
        let ready = styled?.count == text.blocks.count ? styled : nil
        let folded = foldFrom != nil && !showsQuote
        let shown = folded ? Array(text.blocks.prefix(foldFrom ?? 0)) : text.blocks
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // A fold keeps the first blocks, so a block's index is its index in `styled` too.
            ForEach(Array(shown.enumerated()), id: \.offset) { index, block in
                MailBlockView(block: block, styled: ready?[index])
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
        case .picture(let picture):
            MailPictureView(picture: picture)
        case .fineprint:
            Text(runs).font(.caption).foregroundStyle(.secondary)
        case .table(let table):
            MailTableView(table: table)
        }
    }
}

/// A table of data as a grid: columns as wide as their words (to a limit, then wrapping), headers
/// in secondary, a separator between rows. A table wider than the column scrolls sideways on its own,
/// so the message around it keeps its width.
private struct MailTableView: View {
    let table: MailTable
    /// Wider than this, a cell wraps.
    private let widestCell: CGFloat = 220

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MailAttributedText.make(cell.runs))
                                .font(cell.header ? .footnote.weight(.semibold) : .subheadline)
                                .foregroundStyle(cell.header ? .secondary : .primary)
                                .frame(maxWidth: widestCell, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

#endif
