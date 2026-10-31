import SwiftUI

/// One offer about when something is done: what Banana noticed, and two answers
/// (docs/design/ANCHORED-TIMING.md, "Learning it, and moving to Taken"), in the plan's prompt
/// shape (`PromptCard`). Boxed on a page of cards; bare as a List row, which its host tints.
struct TimingOfferCard: View {
    var symbol: String
    var text: String
    /// What it's based on, for VoiceOver; never on screen.
    var hint: String? = nil
    var accept: String
    var decline: String
    var boxed = true
    var identifier: String
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        // The plan's prompt shape: the answer that does something is the button, the other is ×.
        PromptCard(symbol: symbol, title: text, id: identifier, boxed: boxed,
                   dismissLabel: decline, onDismiss: onDecline) {
            Button(accept, action: onAccept)
                .buttonStyle(.primary)
                .accessibilityIdentifier(identifier + ".accept")
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(hint ?? "")
        .accessibilityIdentifier(identifier)
    }
}

/// Taken's offers, where they're acted on: reminders that are something taken, to move in, and
/// moments Taken items have been following. Its own List section on the iPhone (`inList`), a
/// stack of cards on the iPad and Mac page; nothing at all when there's nothing to offer.
struct TakenTimingOffers: View {
    @ObservedObject private var store = AnchorSuggestionStore.shared
    var inList = false

    var body: some View {
        if !store.moves.isEmpty || !store.taken.isEmpty {
            if inList {
                Section { rows }
            } else {
                VStack(spacing: DS.Space.s) { rows }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(store.moves) { offer in
            TimingOfferCard(symbol: ReminderToTaken.kind(offer.title).symbol, text: offer.sentence,
                            accept: "Move", decline: "Not now", boxed: !inList, identifier: "taken.moveOffer",
                            onAccept: { store.move(offer) }, onDecline: { store.notNow(offer) })
                .listRowBackground(inList ? rowWash : nil)
        }
        ForEach(store.taken) { suggestion in
            TimingOfferCard(symbol: "arrow.turn.down.right", text: suggestion.question, hint: suggestion.sentence,
                            accept: "Make it so", decline: "No", boxed: !inList, identifier: "taken.anchorOffer",
                            onAccept: { store.accept(suggestion) }, onDecline: { store.decline(suggestion) })
                .listRowBackground(inList ? rowWash : nil)
        }
    }

    /// The row's own background with the accent wash over it, so an offer reads as one.
    private var rowWash: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            DS.Palette.accent.opacity(DS.Tint.subtle)
        }
    }
}

/// Repeating reminders that have been following a moment, offered it above Plan's Day:
/// "Creatine after workouts?"
/// Nothing at all when there's nothing to offer.
struct ReminderTimingOffers: View {
    @ObservedObject private var store = AnchorSuggestionStore.shared

    var body: some View {
        if !store.reminders.isEmpty {
            VStack(spacing: DS.Space.s) {
                ForEach(store.reminders) { suggestion in
                    TimingOfferCard(symbol: "arrow.turn.down.right", text: suggestion.question, hint: suggestion.sentence,
                                    accept: "Make it so", decline: "No", identifier: "plan.anchorOffer",
                                    onAccept: { store.accept(suggestion) }, onDecline: { store.decline(suggestion) })
                        .padding(.horizontal, DS.Space.m)
                }
            }
        }
    }
}
