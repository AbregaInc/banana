import Combine
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The host's booking link (docs/design/BOOKING.md §12): the handle, the link, and the handle to
/// suggest. What the service last said is kept, so the link is there at once, and read again
/// when Booking opens or something is shared.
///
/// Everything is optimistic: taking a handle shows it at once and the service catches up. A
/// handle the service refuses (taken, reserved) goes back, and Settings › Booking says why under
/// the field. A service that couldn't be reached is asked again later; nothing is said.
@MainActor
final class BookingCenter: ObservableObject {
    static let shared = BookingCenter()

    /// What `GET /v1/booking` last answered.
    @Published private(set) var state: BananaService.BookingState
    /// A handle taken here that the service hasn't confirmed yet: shown as the handle meanwhile.
    @Published private(set) var pendingHandle: String?
    /// The last handle the service (or the local check) refused, and why.
    @Published private(set) var refusal: (handle: String, problem: BookingHandle.Problem)?

    /// The screenshot routes' stand-in for the service (`--booking-preview`): no network, ever.
    let isPreview: Bool
    private let defaults: UserDefaults
    private var accountWatch: AnyCancellable?
    private static let stateKey = "booking.state.v1"
    private static let pendingKey = "booking.pendingHandle.v1"
    /// The Banana account the kept answer belongs to.
    private static let accountKey = "booking.account.v1"

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        #if DEBUG
        isPreview = arguments.contains("--booking-preview")
        #else
        isPreview = false
        #endif
        if isPreview {
            state = Self.previewState(linked: arguments.contains("--booking-linked"))
            pendingHandle = nil
            return
        }
        state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(BananaService.BookingState.self, from: $0) } ?? .init()
        pendingHandle = defaults.string(forKey: Self.pendingKey)
        // Signing in or out changes whether there's a link to offer (`isAvailable`); another
        // account's link is never shown.
        accountWatch = BananaAccount.shared.$account.dropFirst().sink { [weak self] account in
            guard let self else { return }
            self.objectWillChange.send()
            self.accountChanged(to: account?.id, signedIn: BananaAccount.shared.isSignedIn)
        }
    }

    // MARK: - What the screens read

    /// Whether this person can have a link: a Banana account to hold it.
    var isAvailable: Bool { isPreview || (BananaService.isAvailable && BananaAccount.shared.isSignedIn) }

    var handle: String? { pendingHandle ?? state.handle }

    /// The booking site: what the service's links say, else the variant's own.
    var site: String {
        state.site ?? (AppVariant.current == .beta ? "https://beta-book.bananatheapp.com" : "https://book.bananatheapp.com")
    }

    /// The site as shown before a handle: `book.bananatheapp.com/`.
    var sitePrefix: String { (URL(string: site).map(BookingHandle.display) ?? site) + "/" }

    /// The person's link, once the service has confirmed the handle: a handle still on its way
    /// shows in the field, and Copy and Share wait for it.
    var link: URL? { state.handle.flatMap { BookingHandle.link(base: site, handle: $0) } }

    /// The handle to offer when there is none: the service's first suggestion (it knows what is
    /// taken), else one made here from the Google account.
    var suggestion: String? {
        guard handle == nil else { return nil }
        return state.suggested.first
            ?? BookingHandle.ideas(name: state.name, email: GoogleCalendarService.shared.accounts.first?.email).first
    }

    /// The link to share: the person's, or the service's first suggestion (taken once it has been
    /// shared, `shared(_:)`). Never one made here: only the service knows it isn't someone else's,
    /// and a shared link must work.
    var shareURL: URL? { link ?? sharedSuggestion.flatMap { BookingHandle.link(base: site, handle: $0) } }

    private var sharedSuggestion: String? { handle == nil ? state.suggested.first : nil }

    /// Whether there is a link to share or copy now: the Share button, the menu items.
    var canShare: Bool { isAvailable && shareURL != nil }

    /// Whether the service has ever answered here: until it has, a sign-in asks it once.
    private var hasAnswer: Bool { defaults.data(forKey: Self.stateKey) != nil }

    // MARK: - Doing

    /// Asks the service again; a handle taken while it couldn't be reached is sent first.
    func refresh() async {
        guard !isPreview, isAvailable else { return }
        if let pendingHandle { await send(pendingHandle) }
        guard let answer = await BananaAccount.shared.bookingCall(.booking), answer.status == 200,
              let fresh = try? JSONDecoder().decode(BananaService.BookingState.self, from: answer.data) else { return }
        keep(fresh)
    }

    /// From the account's pass: asks only until the service has answered once (then Booking and
    /// sharing ask), or while a handle taken here hasn't reached it.
    func refreshIfUnknown() async {
        guard pendingHandle != nil || !hasAnswer else { return }
        await refresh()
    }

    /// Takes a handle: shown at once, confirmed by the service after. False when it can't be one
    /// (said under the field).
    @discardableResult
    func claim(_ typed: String) -> Bool {
        let handle = BookingHandle.normalised(typed)
        if let problem = BookingHandle.problem(handle) {
            refusal = (handle, problem)
            return false
        }
        refusal = nil
        guard handle != self.handle else { return true }
        setPending(handle)
        Task { await send(handle) }
        return true
    }

    /// A link went out (a share completed, a copy, a shortcut): when it was the suggestion's, the
    /// suggestion is taken, so the link someone now has works. The share and the claim are one tap.
    func shared(_ url: URL) {
        guard link == nil, let suggestion = sharedSuggestion,
              BookingHandle.link(base: site, handle: suggestion) == url else { return }
        claim(suggestion)
    }

    /// Copies the link (⌘⇧L, the menus, the intent). The link copied, or nil when there is none.
    @discardableResult
    func copyLink(confirm: Bool = true) -> URL? {
        guard isAvailable, let url = shareURL else { return nil }
        Self.copy(url.absoluteString)
        shared(url)
        if confirm { ToastCenter.shared.notify("Link copied") }
        return url
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - Plumbing

    private func send(_ handle: String) async {
        if isPreview { return previewAnswer(handle) }
        guard var answer = await BananaAccount.shared.bookingCall(.claimHandle(handle: handle, timeZone: BookingType.deviceZone())) else {
            return   // not reached: kept, and sent again at the next refresh
        }
        // A zone the service doesn't take isn't the handle's fault: again without it (the
        // account's own zone then stands).
        if BananaService.zoneRefused(status: answer.status, data: answer.data) {
            guard let again = await BananaAccount.shared.bookingCall(.claimHandle(handle: handle, timeZone: nil)) else { return }
            answer = again
        }
        guard pendingHandle == handle else { return }   // another was typed meanwhile
        if answer.status == 200, let claimed = try? JSONDecoder().decode(BananaService.ClaimedHandle.self, from: answer.data) {
            var next = state
            next.handle = claimed.handle
            next.link = claimed.link
            next.suggested = []
            setPending(nil)
            keep(next)
        } else if let problem = BananaService.handleRefusal(status: answer.status, data: answer.data) {
            refusal = (handle, problem)
            setPending(nil)
            if problem == .taken { await refreshSuggestions() }
        }
    }

    /// After a suggestion turned out taken: the service's next ones.
    private func refreshSuggestions() async {
        guard let answer = await BananaAccount.shared.bookingCall(.booking), answer.status == 200,
              let fresh = try? JSONDecoder().decode(BananaService.BookingState.self, from: answer.data) else { return }
        keep(fresh)
    }

    private func setPending(_ handle: String?) {
        pendingHandle = handle
        guard !isPreview else { return }
        if let handle { defaults.set(handle, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
    }

    private func keep(_ fresh: BananaService.BookingState) {
        state = fresh
        guard !isPreview, let data = try? JSONEncoder().encode(fresh) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    /// Signed out, or a different account: what was kept for the last one goes. (`account` is
    /// nil at launch before the first answer, while still signed in: nothing goes then.)
    func accountChanged(to id: String?, signedIn: Bool) {
        guard !isPreview else { return }
        let kept = defaults.string(forKey: Self.accountKey)
        if let id {
            if let kept, kept != id { forget() }
            defaults.set(id, forKey: Self.accountKey)
        } else if !signedIn {
            forget()
            defaults.removeObject(forKey: Self.accountKey)
        }
    }

    private func forget() {
        state = .init()
        refusal = nil
        setPending(nil)
        defaults.removeObject(forKey: Self.stateKey)
    }

    // MARK: - Preview

    private static func previewState(linked: Bool) -> BananaService.BookingState {
        let site = "https://book.bananatheapp.com"
        return BananaService.BookingState(
            handle: linked ? "noor" : nil, link: linked ? URL(string: "\(site)/noor") : nil,
            suggested: linked ? [] : ["noor", "noor-haddad", "noorh"], name: "Noor Haddad",
            timeZone: "America/New_York",
            types: [.init(slug: "meeting", title: "Meeting", active: true, link: URL(string: "\(site)/noor/meeting")!)])
    }

    /// The preview's service: "sam" and "taken" are someone else's.
    private func previewAnswer(_ handle: String) {
        guard pendingHandle == handle else { return }
        if ["sam", "taken"].contains(handle) {
            refusal = (handle, .taken)
            setPending(nil)
            return
        }
        setPending(nil)
        var next = state
        next.handle = handle
        next.link = BookingHandle.link(base: site, handle: handle)
        next.suggested = []
        keep(next)
    }
}
