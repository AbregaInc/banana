#if DEBUG || MAIL_FIXTURES
import XCTest

/// A session on its own sample source, for the tests of writing mail that need time: the clock is
/// the mail code's own `ManualMailClock`, which a test moves by exactly as much as it means to, and
/// the source sleeps on that same clock, so a scheduled message wakes when the test says an hour
/// has passed and never because one has. Timers wait to be fired; toasts are recorded.
@MainActor
final class MailWriteHarness {
    let manual: ManualMailClock
    var source: MailFixtureSource!
    var session: MailSession!
    var toasts: [MailToast] = []
    var toastUndo: (@MainActor () -> Void)?
    var timers: [(delay: TimeInterval, work: @MainActor () -> Void, cancelled: Bool)] = []

    static let account = MailFixtureConversations.account

    init(manual: ManualMailClock = ManualMailClock(), defaults: UserDefaults? = nil, device: String = "Mac") {
        self.manual = manual
        source = MailFixtureSource(clock: { manual.now }, wakeClock: manual, defaults: defaults)
        session = MailSession(
            source: source, now: source.now, deviceName: device,
            timers: MailTimers { [unowned self] delay, work in
                self.timers.append((delay, work, false))
                let index = self.timers.count - 1
                return { self.timers[index].cancelled = true }
            },
            clock: { manual.now },
            present: { [unowned self] toast, undo in
                self.toasts.append(toast)
                self.toastUndo = undo
            })
        session.enter()
    }

    var now: Date { manual.now }
    var composer: MailComposerModel? { session.composer }

    func id(_ key: String) -> MailConversationID {
        MailConversationID(account: Self.account, thread: key)
    }

    func conversation(_ key: String) async -> MailConversation? {
        await source.conversation(id(key))
    }

    /// The conversation, which a test says is there.
    func thread(_ key: String) async throws -> MailConversation {
        let found = await source.conversation(id(key))
        return try XCTUnwrap(found, "no conversation \(key)")
    }

    /// The newest message of a conversation.
    func lastMessage(_ key: String = "q3") async throws -> MailMessage {
        let conversation = try await thread(key)
        return try XCTUnwrap(conversation.messages.last)
    }

    /// A reply to a conversation, written in it, with the draft arrived. No caret is asked for.
    func reply(to key: String, _ start: (MailConversationID) -> MailComposeStart = { .reply($0) }) async -> MailComposerModel {
        session.begin(start(id(key)), requestFocus: false)
        let composer = self.composer!
        await composer.waitForDraft()
        return composer
    }

    /// A new message, with the draft arrived.
    func newMessage() async -> MailComposerModel {
        session.begin(.new, requestFocus: false)
        let composer = self.composer!
        await composer.waitForDraft()
        return composer
    }

    /// A key as the Mac's monitor gives it to Mail.
    @discardableResult
    func press(_ key: Character, shift: Bool = false) -> Bool {
        session.handle(.character(Character(key.lowercased())), shift: shift,
                       typed: shift ? key.uppercased() : String(key))
    }

    /// The rows a place holds now.
    func rows(_ mailbox: MailMailbox) -> [MailRow] {
        var rows: [MailRow] = []
        let watching = source.observeList(MailScope(place: .mailbox(mailbox)), limit: 100) { rows = $0.rows }
        watching.cancel()
        return rows
    }

    /// What the control column would say a place holds.
    func count(_ mailbox: MailMailbox) -> Int? {
        var counts: [MailMailbox: MailPlaceCount] = [:]
        let watching = source.observePlaces { counts = $0.mailboxCounts }
        watching.cancel()
        return counts[mailbox]?.total.value
    }

    /// A time of day a long way ahead of the manual clock's: the messages these tests schedule.
    func later(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// A set of defaults that is this test's alone and is gone when it is.
    static func ephemeralDefaults() -> UserDefaults {
        let name = "mail-write-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
#endif
