import SwiftUI

/// What automatic ad skipping just did, and the way back.
///
/// Non-modal on purpose, and it goes away by itself. Most listening happens with the phone in a
/// pocket, so anything that has to be dismissed is a chore imposed on someone who was not looking
/// at the screen — and the thing being reported is, by design, the case where Banana was right.
/// The listener needs to be *able* to find out what happened and undo it, not made to acknowledge
/// it. Undo counts as a correction: it is the clearest statement there is that a skip was wrong.
struct SkipNoticeBar: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        if let notice = player.skipNotice {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "forward.end.alt.fill")
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.accent)
                Text(notice.summary)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button("Undo") { player.undoLastSkip() }
                    .buttonStyle(.inline)
                    .accessibilityIdentifier("adSkip.undo")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .floatingCapsule()
            .padding(.horizontal, DS.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy, value: notice.id)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(notice.summary)
        }
    }
}
