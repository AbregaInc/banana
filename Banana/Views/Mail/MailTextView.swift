#if !BANANA_PUBLIC
import SwiftUI

/// A message's text, drawn natively from its meaning (`MailText`): paragraphs, quotes, lists,
/// headings, preformatted lines and rules, with system link handling.
struct MailTextView: View {
    let text: MailText
    /// The blocks already styled off the main thread (`MailReaderModel.styled`); styled here
    /// only when absent.
    var styled: [AttributedString]? = nil
    /// The prepared body's `quoteStartsAt`: quoted history waits behind one button.
    var foldFrom: Int? = nil
    var foldEntireTail = false
    var timeNotes: [Int: [MailReaderTime.Note]] = [:]
    @State private var showsQuote = false

    var body: some View {
        let ready = styled?.count == text.blocks.count ? styled : nil
        let hidden = MailQuoteFolding.hiddenRange(in: text.blocks, from: foldFrom, expanded: showsQuote,
                                                 entireTail: foldEntireTail)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(text.blocks.indices, id: \.self) { index in
                if hidden?.lowerBound == index { showQuoteButton }
                if hidden?.contains(index) != true {
                    if let notes = timeNotes[index] {
                        MailLocalTimeParagraph(runs: ready?[index] ?? MailAttributedText.make(text.blocks[index].runs), notes: notes)
                    } else {
                        MailBlockView(block: text.blocks[index], styled: ready?[index])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showQuoteButton: some View {
        Button { showsQuote = true } label: {
            Label("Show quoted text", systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityIdentifier("mail.body.quote")
    }

}

private struct MailLocalTimeParagraph: View {
    let runs: AttributedString
    let notes: [MailReaderTime.Note]
    @Environment(\.timeZone) private var zone
    @Environment(\.locale) private var locale

    var body: some View {
        let rendered = annotatedText()
        if runs.runs.contains(where: { $0.link != nil }) {
            rendered.text.font(.body)
        } else {
            rendered.text.font(.body).accessibilityLabel(Text(rendered.spoken))
        }
    }

    private func annotatedText() -> (text: Text, spoken: String) {
        var text = Text("")
        var spoken = ""
        var previous = runs.startIndex
        for note in notes where zone.secondsFromGMT(for: note.date) != note.sourceZone.secondsFromGMT(for: note.date) {
            guard let end = runs.characters.index(runs.startIndex, offsetBy: note.end, limitedBy: runs.endIndex),
                  end >= previous else { continue }
            let prefix = AttributedString(runs[previous..<end])
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = zone
            var sourceCalendar = localCalendar
            sourceCalendar.timeZone = note.sourceZone
            let components: Set<Calendar.Component> = [.year, .month, .day]
            let rollover = localCalendar.dateComponents(components, from: note.date)
                != sourceCalendar.dateComponents(components, from: note.date)
            let value = note.date.formatted(Date.FormatStyle(date: rollover ? .abbreviated : .omitted,
                                                            time: .shortened, locale: locale, timeZone: zone))
            let shortZone = zone.abbreviation(for: note.date) ?? zone.identifier
            let longZone = zone.localizedName(for: zone.isDaylightSavingTime(for: note.date) ? .daylightSaving : .standard,
                                               locale: locale) ?? shortZone
            let badge = Text("(\(Self.mark) \(value) \(shortZone))")
            text = Text("\(text)\(Text(prefix)) \(badge)")
            spoken += String(prefix.characters) + ", Banana, your local time, \(value) \(longZone), "
            previous = end
        }
        let tail = AttributedString(runs[previous..<runs.endIndex])
        return (Text("\(text)\(Text(tail))"), spoken + String(tail.characters))
    }

    private static let mark: Image = {
        let size = CGSize(width: 14, height: 14)
        #if os(macOS)
        guard let original = NSImage(named: "BrandMark") else { return Image("BrandMark") }
        return Image(nsImage: NSImage(size: size, flipped: false) { rect in
            original.draw(in: rect)
            return true
        })
        #else
        guard let original = UIImage(named: "BrandMark") else { return Image("BrandMark") }
        return Image(uiImage: UIGraphicsImageRenderer(size: size).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        })
        #endif
    }()
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
