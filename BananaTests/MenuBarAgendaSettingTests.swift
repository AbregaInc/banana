import XCTest

/// The menu-bar switch moved off a dotted `@AppStorage` key (a continuous re-render, the 26 Sep
/// storm). Nobody's setting may change with it: off stays off, on stays on, and a choice made
/// since is never overwritten by what the old key still holds.
final class MenuBarAgendaSettingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "MenuBarAgendaSettingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheNewKeyHasNoDot() {
        XCTAssertFalse(MenuBarAgendaSetting.key.contains("."),
                       "a dotted key is read as a key path, and re-renders its screen without end")
        XCTAssertTrue(MenuBarAgendaSetting.legacyKey.contains("."))
    }

    func testAnOldOffIsCarriedOver() {
        defaults.set(false, forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MenuBarAgendaSetting.key) as? Bool, false,
                       "someone who turned the menu bar item off must not find it back on")
    }

    func testAnOldOnIsCarriedOver() {
        defaults.set(true, forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MenuBarAgendaSetting.key) as? Bool, true)
    }

    /// Nothing stored: nothing written, so the readers' own default (on) applies as it always did.
    func testNothingStoredWritesNothing() {
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertNil(defaults.object(forKey: MenuBarAgendaSetting.key))
        XCTAssertNil(defaults.object(forKey: MenuBarAgendaSetting.legacyKey))
    }

    func testAnAlreadyMigratedValueIsLeftAlone() {
        defaults.set(true, forKey: MenuBarAgendaSetting.key)
        defaults.set(false, forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MenuBarAgendaSetting.key) as? Bool, true,
                       "the new key is the person's current choice; the old one is stale")
    }

    /// "Once": a switch flipped after the move is not undone by the next launch's migration.
    func testACarriedValueIsCarriedOnlyOnce() {
        defaults.set(false, forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        defaults.set(true, forKey: MenuBarAgendaSetting.key)   // turned back on in Settings
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MenuBarAgendaSetting.key) as? Bool, true)
    }

    func testTheOldKeyIsLeftForAnOlderBuild() {
        defaults.set(false, forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MenuBarAgendaSetting.legacyKey) as? Bool, false)
    }

    func testSomethingThatIsNotASwitchIsNotCarried() {
        defaults.set("off", forKey: MenuBarAgendaSetting.legacyKey)
        MenuBarAgendaSetting.migrateLegacyKey(in: defaults)
        XCTAssertNil(defaults.object(forKey: MenuBarAgendaSetting.key))
    }
}
