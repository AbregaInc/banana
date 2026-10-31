#if !BANANA_PUBLIC
import SwiftUI

/// The control column: where you are in Mail. The slice has three places, from the sample
/// source — Inbox, Starred, Done — each with how many it holds, the current one marked. Choosing
/// one shows its list. Accounts, splits and labels join this column with their screens.
struct MailControlColumn: View {
    let session: MailSession
    @ObservedObject var places: MailPlacesModel
    @ObservedObject var navigation: MailNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mail")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, DS.Space.l)
                .frame(height: DS.Mail.header)
            ForEach(MailPlacesModel.all) { place in
                MailPlaceRow(place: place, count: places.total(of: place.mailbox),
                             isCurrent: place.mailbox == navigation.scope.mailbox) {
                    session.show(place.mailbox)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xs)
        // A container, so each place keeps its own identifier under this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.control)
    }
}

private struct MailPlaceRow: View {
    let place: MailPlacesModel.Place
    let count: Int?
    let isCurrent: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: place.symbol)
                    .frame(width: DS.Mail.glyphSlot)
                    .foregroundStyle(isCurrent ? DS.Palette.accent : .secondary)
                Text(place.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer(minLength: DS.Space.xs)
                if let count {
                    Text(MailToastText.number(count))
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: DS.Mail.oneLineRow)
            .background(isCurrent ? DS.Palette.selection : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(MailID.place(place.title))
    }
}

#endif
