import SwiftUI

extension View {
    /// The app's card on a grouped background: the look of a list's rows, for content that isn't
    /// a list (the briefing, the post-workout review). Those two had a card style of their own —
    /// a grey wash with its own corner — from before the design tokens.
    func groupedCard() -> some View {
        padding(DS.Space.l).dsCard()
    }

    /// The page those cards sit on, as a list's background is.
    func groupedPage() -> some View {
        background(Color(.systemGroupedBackground))
    }
}
