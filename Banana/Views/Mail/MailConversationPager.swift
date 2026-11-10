#if !BANANA_PUBLIC
#if os(iOS)
import SwiftUI
import UIKit

/// The open conversation as one page among its neighbours in the list it was opened from, as in
/// Gmail: a swipe left shows the next older conversation, a swipe right the newer one. The queue
/// is the list as it is shown — the place, a label, a search, its filters, in its order, with the
/// rows that load as he goes (the list model pages ahead of the cursor as `J` does) — and at
/// either end the page rubber-bands, never wraps.
///
/// A native paging scroll view, never a drag gesture (a `DragGesture` stops scroll views on
/// iOS 26: MAIL-UX O3). Three pages at most are alive: the newer neighbour, the open one and the
/// older neighbour. Each neighbour's reader is made ahead (`MailSession.reader(for:)`), so its
/// header and whatever body the device has prepared are drawn before the page comes on screen;
/// nothing is fetched for a page until it shows.
///
/// When a swipe comes to rest on a neighbour it opens as `J` or `K` opens it (T12): the cursor
/// follows, the read delay starts, the direction of travel is set — so Done from the reader
/// advances the way he was swiping (T16). Inside a page, a pan that starts on content that
/// scrolls sideways (a wide table, a wide picture) scrolls that content first: the inner scroll
/// view has the touch before the pager (UIKit's nesting).
struct MailConversationPager: View {
    let session: MailSession
    /// The open conversation's reader. Not observed here: each page observes its own.
    let reader: MailReaderModel
    let feed: MailListFeed
    let inlineComposer: Bool
    /// False while a composer is open: what he is writing belongs to this conversation.
    let swipes: Bool

    @State private var pages: [MailReaderModel]
    /// Where the pages are. Told explicitly where to be whenever the pages change: a scroll view
    /// keeps its offset, not the page, when pages are added or removed before the one on screen.
    @State private var scroll = ScrollPosition(idType: MailConversationID.self)
    @State private var phase: ScrollPhase = .idle
    /// A finger moved the pages since they last came to rest: only that settles on a neighbour.
    @State private var swiped = false
    /// The list changed while a finger or a fling was moving the pages: the neighbours are worked
    /// out again when they come to rest, never under the finger.
    @State private var stale = false

    init(session: MailSession, reader: MailReaderModel, feed: MailListFeed, inlineComposer: Bool, swipes: Bool) {
        self.session = session
        self.reader = reader
        self.feed = feed
        self.inlineComposer = inlineComposer
        self.swipes = swipes
        _pages = State(initialValue: Self.pages(around: reader, in: session))
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(pages, id: \.id) { page in
                    MailConversationContent(session: session, reader: page, inlineComposer: inlineComposer,
                                            isShown: page.id == reader.id)
                        .containerRelativeFrame(.horizontal)
                        // A neighbour is not read out beside the page on screen.
                        .accessibilityHidden(page.id != reader.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition($scroll)
        .scrollIndicators(.hidden)
        .scrollDisabled(!swipes)
        .accessibilityIdentifier(MailID.pager)
        .onAppear { show(reader.id) }
        .onScrollPhaseChange { _, new in
            phase = new
            if new == .interacting { swiped = true }
            if new == .idle { cameToRest() }
        }
        // J, K, the menu's Newer and Older, and Done's advance open another conversation without
        // a swipe; a swipe that settled opens its neighbour. Either way the pages are made around
        // it, and it is shown.
        .onChange(of: reader.id) { _, _ in refresh() }
        .onReceive(feed.$shown.dropFirst()) { _ in
            if phase == .idle { refresh() } else { stale = true }
        }
    }

    /// The pages have come to rest. After his swipe, on a neighbour, that conversation opens; if
    /// the list changed under the swipe so that it is no longer one, the open one is shown again.
    private func cameToRest() {
        let landed = scroll.viewID(type: MailConversationID.self)
        let byHand = swiped
        swiped = false
        if let landed, landed != reader.id {
            if byHand, session.settle(on: landed) { return }
            show(reader.id)
        }
        if stale {
            stale = false
            refresh()
        }
    }

    private func refresh() {
        let next = Self.pages(around: reader, in: session)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if next.map(\.id) != pages.map(\.id) { pages = next }
            scroll.scrollTo(id: reader.id)
        }
        session.keepPreparedNeighbours()
    }

    private func show(_ id: MailConversationID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scroll.scrollTo(id: id) }
    }

    private static func pages(around reader: MailReaderModel, in session: MailSession) -> [MailReaderModel] {
        var pages = [reader]
        let model = session.model
        if let newer = model.neighbourID(of: reader.id, .newer) { pages.insert(session.reader(for: newer), at: 0) }
        if let older = model.neighbourID(of: reader.id, .older) { pages.append(session.reader(for: older)) }
        return pages
    }
}

/// The open conversation's left edge, as a pushed screen's: a pan from the edge pulls the screen
/// away over the list beneath, and let go past a third of the width (or flicked) it closes. The
/// pager's own swipe and every scroll view wait for the edge to fail, so the edge always means
/// Back and never "newer", as in Gmail.
struct MailEdgeBack: ViewModifier {
    let session: MailSession
    @State private var pull: CGFloat = 0
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: pull)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(MailEdgePan(changed: { pull = max(0, $0) }, ended: ended))
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        let closes = width > 0 && (translation > width / 3 || velocity > 600) && velocity > -200
        if closes {
            withAnimation(.snappy(duration: 0.22)) { pull = width } completion: { session.close() }
        } else {
            withAnimation(.snappy(duration: 0.25)) { pull = 0 }
        }
    }
}

/// The screen-edge pan behind `MailEdgeBack`, the system's own recognizer.
private struct MailEdgePan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let recognizer = UIScreenEdgePanGestureRecognizer()
        recognizer.edges = .left
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed: changed(translation)
        case .ended: ended(translation, recognizer.velocity(in: nil).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Every scroll view's pan — the pager's, the thread's, a wide table's — waits for the edge.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
#endif
#endif
