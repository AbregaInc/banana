import XCTest

/// Coming back to the app must land where the person left it.
///
/// iOS replaces the whole view tree a moment after backgrounding (AppVisibility), which used to
/// drop the selected tab and the open note: open a note, glance at another app, come back to
/// Plan. These pin the memory that replaced the views' own `@State`.
@MainActor
final class ShellNavigationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "ShellNavigationTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let noteID = UUID()
    private let left = Date(timeIntervalSince1970: 1_790_000_000)

    func testFreshInstallOpensOnPlan() {
        let nav = ShellNavigation(defaults: defaults, now: left)
        XCTAssertEqual(nav.state.tab, .plan)
        XCTAssertTrue(nav.state.notes.isEmpty)
    }

    func testRelaunchSoonAfterLeavingReturnsToTheOpenNote() {
        let before = ShellNavigation(defaults: defaults, now: left)
        before.state.tab = .notes
        before.state.notes = [noteID]
        before.save(now: left)

        // iOS reclaimed the process in the background; they come back 20 minutes later.
        let after = ShellNavigation(defaults: defaults, now: left.addingTimeInterval(20 * 60))
        XCTAssertEqual(after.state.tab, .notes)
        XCTAssertEqual(after.state.notes, [noteID])
    }

    func testAHalfWrittenNoteIsStillOpenAfterAnotherApp() {
        let before = ShellNavigation(defaults: defaults, now: left)
        before.state.tab = .notes
        before.state.noteComposer = "new"
        before.save(now: left)

        let after = ShellNavigation(defaults: defaults, now: left.addingTimeInterval(60))
        XCTAssertEqual(after.state.noteComposer, "new")
    }

    func testStateSavedBeforeTheComposerExistedStillRestores() throws {
        let old = #"{"tab":"notes","notes":[],"library":[],"savedAt":\#(left.timeIntervalSinceReferenceDate)}"#
        let state = try JSONDecoder().decode(ShellState.self, from: Data(old.utf8))
        XCTAssertEqual(state.tab, .notes)
        XCTAssertNil(state.noteComposer)
    }

    // MARK: Mail

    func testStateSavedBeforeMailExistedStillRestoresWithNoMailState() throws {
        let old = #"{"tab":"library","notes":[],"library":[],"savedAt":\#(left.timeIntervalSinceReferenceDate)}"#
        let state = try JSONDecoder().decode(ShellState.self, from: Data(old.utf8))
        XCTAssertEqual(state.tab, .library)
        XCTAssertNil(state.mail)
    }

    func testTheOpenMailConversationRoundTrips() throws {
        var state = ShellState(tab: .mail)
        state.mail = MailShellState(open: "noor@plan.example|q3")
        let again = try JSONDecoder().decode(ShellState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again.tab, .mail)
        XCTAssertEqual(again.mail?.open, "noor@plan.example|q3")
        XCTAssertEqual(again.mail?.open.flatMap(MailConversationID.init(text:)),
                       MailConversationID(account: "noor@plan.example", thread: "q3"))
    }

    func testAMailStateThatCannotBeReadDoesNotLoseTheRest() throws {
        // A later build's mail field, or damage: the tab and the stacks still restore.
        let odd = #"{"tab":"library","mail":{"open":7},"savedAt":\#(left.timeIntervalSinceReferenceDate)}"#
        let state = try JSONDecoder().decode(ShellState.self, from: Data(odd.utf8))
        XCTAssertEqual(state.tab, .library)
        XCTAssertNil(state.mail)
    }

    func testRelaunchTheNextMorningOpensOnPlan() {
        let before = ShellNavigation(defaults: defaults, now: left)
        before.state.tab = .notes
        before.state.notes = [noteID]
        before.save(now: left)

        let after = ShellNavigation(defaults: defaults, now: left.addingTimeInterval(9 * 60 * 60))
        XCTAssertEqual(after.state, ShellState())
    }

    func testEveryChangeIsWritten() {
        let nav = ShellNavigation(defaults: defaults, now: left)
        nav.state.tab = .library
        nav.state.library = [noteID]
        let restored = ShellState.restored(from: defaults.data(forKey: ShellNavigation.defaultsKey))
        XCTAssertEqual(restored.tab, .library)
        XCTAssertEqual(restored.library, [noteID])
    }

    func testSavedInTheFutureIsIgnored() {
        // A clock set back (or a restored backup) must not pin the app to a stale screen forever.
        var state = ShellState(tab: .notes, notes: [noteID])
        state.savedAt = left.addingTimeInterval(3600)
        let data = try! JSONEncoder().encode(state)
        XCTAssertEqual(ShellState.restored(from: data, now: left), ShellState())
    }

    func testGarbageFallsBackToPlan() {
        XCTAssertEqual(ShellState.restored(from: Data("nope".utf8), now: left), ShellState())
        XCTAssertEqual(ShellState.restored(from: nil, now: left), ShellState())
    }

    func testPruneDropsDeletedButWaitsForTheStoreToLoad() {
        let other = UUID()
        XCTAssertEqual(ShellState.pruned([noteID], known: [other]), [])
        XCTAssertEqual(ShellState.pruned([noteID], known: [noteID, other]), [noteID])
        XCTAssertEqual(ShellState.pruned([noteID], known: []), [noteID],
                       "an empty store is one that hasn't loaded, not one where everything was deleted")
    }
}
