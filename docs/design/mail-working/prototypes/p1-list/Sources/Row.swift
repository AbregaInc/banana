import SwiftUI

/// The row: sender, subject, one-line snippet, date, unread dot. Fixed height (64 pt compact on
/// iPhone, 32 pt single-line on the Mac). `Equatable`, applied with `.equatable()` by every host.
/// The cursor highlight is not an input of this view: it is drawn by `MarkBackground`, which
/// observes this row's own `RowMark`.
struct MailRow: View, Equatable {
    let conv: Conversation
    let mark: RowMark

    static func == (a: MailRow, b: MailRow) -> Bool { a.conv == b.conv && a.mark === b.mark }

    var body: some View {
        let _ = Counters.noteRow(conv.id)
        #if os(macOS)
        HStack(spacing: 8) {
            Circle().fill(conv.unread ? Color.blue : Color.clear).frame(width: 8, height: 8)
            Text(conv.sender).fontWeight(.semibold).lineLimit(1).frame(width: 150, alignment: .leading)
            (Text(conv.subject).fontWeight(.medium) + Text("  " + conv.snippet).foregroundStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(conv.date).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: RowMetrics.height)
        .background(MarkBackground(mark: mark, id: conv.id))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("row-\(conv.id)")
        #else
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(conv.unread ? Color.blue : Color.clear).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conv.sender).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(conv.date).font(.footnote).foregroundStyle(.secondary)
                }
                Text(conv.subject).font(.subheadline).lineLimit(1)
                Text(conv.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(height: RowMetrics.height, alignment: .top)
        .background(MarkBackground(mark: mark, id: conv.id))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("row-\(conv.id)")
        #endif
    }
}

/// The leaf. Observes one `RowMark`; re-evaluates when the cursor arrives or leaves this row, and
/// when the row becomes or stops being the probed row. Nothing above it re-evaluates.
struct MarkBackground: View {
    @ObservedObject var mark: RowMark
    let id: Int

    var body: some View {
        let _ = Counters.markBody += 1
        let fill = mark.hasCursor ? Color.accentColor.opacity(0.22) : Color.clear
        if mark.probed {
            // Exists on one row only, so the other rows pay nothing for being measurable.
            fill
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY },
                                  action: { Probe.report(id, $0) })
                .onDisappear { Probe.gone(id) }
        } else {
            fill
        }
    }
}

/// The three row actions every host offers: Done / Trash trailing, Snooze / Unread leading. They only
/// count (the UI test reads the counters); the real list would act through the model.
enum RowActions {
    static let trailing = ["Done", "Trash"]
    static let leading = ["Snooze", "Unread"]
}
