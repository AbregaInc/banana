#if DEBUG || MAIL_FIXTURES
import XCTest

/// What the reading pane, the details column and the control column are given, prepared: the
/// facts about a conversation, what a message's card says, the places and their counts, and the
/// two toggles that hide a column.
@MainActor
final class MailColumnsTests: XCTestCase {

    private let account = MailFixtureConversations.account

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: account, thread: key)
    }

    private func conversation(_ key: String) async throws -> MailConversation {
        let found = await MailFixtureSource().conversation(id(key))
        return try XCTUnwrap(found)
    }

    // MARK: Facts

    func testTheFactsOfTheOrdinaryConversation() async throws {
        let facts = MailConversationFacts(try await conversation("q3"))
        XCTAssertEqual(facts.participants.map(\.address),
                       ["sam@lee.example", "jane@parkdesign.example", "noor@plan.example"],
                       "who wrote, in order of first appearance, then who was written to")
        XCTAssertEqual(facts.participants.map(\.wrote), [2, 1, 0])
        XCTAssertEqual(facts.participants.map(\.isMe), [false, false, true])
        XCTAssertEqual(facts.messageCount, 3)
        XCTAssertEqual(facts.unreadCount, 1)
        XCTAssertEqual(facts.messageLine, "3 messages, 1 unread")
        XCTAssertEqual(facts.attachments.map(\.name), ["Q3-revenue.xlsx", "churn-chart.png"])
        XCTAssertEqual(facts.attachments.map(\.bytes), [412_000, 188_000])
        XCTAssertFalse(facts.attachments[0].sizeText.isEmpty)
        XCTAssertEqual(facts.labels, ["Invoices"])
        XCTAssertFalse(facts.isInvitation)
        XCTAssertLessThan(try XCTUnwrap(facts.first), try XCTUnwrap(facts.last))
        XCTAssertNotEqual(facts.firstText, facts.lastText)
    }

    func testAPersonIsOneParticipantHoweverManyTimesTheyAppear() async throws {
        let facts = MailConversationFacts(try await conversation("forty"))
        XCTAssertEqual(facts.participants.count, 9)
        XCTAssertEqual(Set(facts.participants.map(\.id)).count, 9)
        XCTAssertEqual(facts.participants.map(\.wrote).reduce(0, +), 40, "every message has one author")
        XCTAssertEqual(facts.messageLine, "40 messages, 3 unread")
    }

    func testAnInvitationAndANamelessSender() async throws {
        let invite = MailConversationFacts(try await conversation("invite"))
        XCTAssertTrue(invite.isInvitation)
        XCTAssertEqual(invite.messageLine, "1 message, 1 unread")
        let nameless = MailConversationFacts(try await conversation("no-name"))
        XCTAssertNil(nameless.participants.first?.name, "the address is what there is to show")
    }

    func testAMessageCardSaysWhoWroteToWhomWhenAndWhatWasAttached() async throws {
        let q3 = try await conversation("q3")
        let first = MailMessageDisplay(q3.messages[0])
        XCTAssertEqual(first.sender, "Sam Lee")
        XCTAssertEqual(first.recipients, "to me, Jane")
        XCTAssertEqual(first.attachments.count, 2)
        XCTAssertTrue(first.attachments[0].hasPrefix("Q3-revenue.xlsx \u{00B7} "))
        XCTAssertFalse(first.date.isEmpty)
        XCTAssertEqual(first.firstLine, q3.messages[0].firstLine)
        let mine = try await conversation("me-newest")
        XCTAssertEqual(MailMessageDisplay(mine.messages[1]).sender, "me")
    }

    // MARK: The reader's prepared values

    func testTheReaderPreparesItsTitleItsCardsAndItsFactsWhenTheConversationArrives() async throws {
        let source = MailFixtureSource()
        let reader = MailReaderModel(id: id("q3"), source: source)
        XCTAssertEqual(reader.title, "Q3 numbers before Thursday")
        XCTAssertEqual(reader.messages.count, 3)
        XCTAssertEqual(reader.facts?.messageCount, 3)
        // And again when it changes: starring does not change the facts, reading does.
        source.apply(.read(true), to: .conversations([id("q3")]))
        XCTAssertEqual(reader.facts?.unreadCount, 0)
        XCTAssertEqual(reader.facts?.messageLine, "3 messages")
    }

    // MARK: Places

    func testThePlacesAndTheirCountsFollowTheMailbox() {
        let source = MailFixtureSource()
        let places = MailPlacesModel(source: source)
        XCTAssertEqual(MailPlacesModel.all.map(\.title), ["Inbox", "Starred", "Drafts", "Scheduled", "Done"])
        XCTAssertEqual(places.total(of: .inbox), 40)
        XCTAssertEqual(places.total(of: .done), 0)
        let starred = places.total(of: .starred) ?? 0
        XCTAssertGreaterThan(starred, 0)

        source.apply(.done, to: .conversations([id("q3")]))   // starred, and now Done
        XCTAssertEqual(places.total(of: .inbox), 39)
        XCTAssertEqual(places.total(of: .done), 1)
        XCTAssertEqual(places.total(of: .starred), starred, "Done does not unstar it")
        XCTAssertEqual(places.total(of: .drafts), 0, "nothing written yet")
        XCTAssertNil(places.total(of: .sent), "a place the slice does not have")
    }

    func testAPlaceHasATitleAndAScopeKnowsItsMailbox() {
        XCTAssertEqual(MailPlacesModel.title(of: MailScope(place: .mailbox(.starred))), "Starred")
        XCTAssertEqual(MailPlacesModel.title(of: MailScope(place: .search("x"))), "Search results")
        XCTAssertEqual(MailPlacesModel.title(of: MailScope(place: .mailbox(.sent))), "Mail")
        XCTAssertEqual(MailScope(place: .mailbox(.done)).mailbox, .done)
        XCTAssertNil(MailScope(place: .search("x")).mailbox)
    }

    // MARK: The toggles

    func testTheTogglesStartOnAndAreKeptWhenHeMakesThem() throws {
        let suite = "MailColumnsTests.toggles"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = MailNavigation(scope: MailSession.inbox, defaults: defaults)
        XCTAssertTrue(first.showsPane)
        XCTAssertTrue(first.showsDetails)

        first.setPane(false)
        first.setDetails(false)
        let later = MailNavigation(scope: MailSession.inbox, defaults: defaults)
        XCTAssertFalse(later.showsPane, "kept for the next launch")
        XCTAssertFalse(later.showsDetails)
    }

    func testAToggleALaunchRouteMakesIsNotKept() throws {
        let suite = "MailColumnsTests.route"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let navigation = MailNavigation(scope: MailSession.inbox, defaults: defaults)
        navigation.setPane(false, persist: false)
        XCTAssertFalse(navigation.showsPane)
        XCTAssertTrue(MailNavigation(scope: MailSession.inbox, defaults: defaults).showsPane,
                      "a screenshot must not change what the next real launch shows")
    }

    func testTheKeysAreDotFreeAndWithNoDefaultsNothingIsKept() {
        XCTAssertFalse(MailNavigation.paneKey.contains("."))
        XCTAssertFalse(MailNavigation.detailsKey.contains("."))
        let navigation = MailNavigation(scope: MailSession.inbox, defaults: nil)
        navigation.setPane(false)
        XCTAssertFalse(navigation.showsPane)
        XCTAssertTrue(MailNavigation(scope: MailSession.inbox, defaults: nil).showsPane)
    }
}
#endif
