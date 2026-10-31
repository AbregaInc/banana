import XCTest

/// The words for what a routine does (`RoutineWording`): they say what the app does, and no more.
final class RoutineWordingTests: XCTestCase {
    func testNothingPromisesANotificationThatIsNotSent() {
        // "Nudge sends a one-tap notification" was on the Routines screen; no such notification
        // has ever existed.
        let all = [RoutineWording.Level.auto, .nudge, .manual].flatMap {
            [RoutineWording.label($0), RoutineWording.sentence($0)]
        }
        for text in all {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("notification"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("nudge"), text)
        }
    }

    func testEachKindSaysHowItStarts() {
        XCTAssertEqual(RoutineWording.label(.auto), "Auto")
        XCTAssertEqual(RoutineWording.label(.nudge), "Scheduled")
        XCTAssertEqual(RoutineWording.label(.manual), "Manual")
        XCTAssertTrue(RoutineWording.sentence(.auto).contains("by itself"))
        XCTAssertTrue(RoutineWording.sentence(.nudge).contains("press Start"))
        XCTAssertTrue(RoutineWording.sentence(.manual).contains("press Start"))
    }

    func testWhatStartPlays() {
        XCTAssertEqual(RoutineWording.plays(episode: "The Daily", music: true, slot: true), "Plays \u{201C}The Daily\u{201D}",
                       "an episode comes first, as when it starts")
        XCTAssertEqual(RoutineWording.plays(episode: nil, music: true, slot: true), "Plays its music")
        XCTAssertEqual(RoutineWording.plays(episode: nil, music: false, slot: true), "Plays its wake audio")
        XCTAssertNil(RoutineWording.plays(episode: nil, music: false, slot: false), "nothing to play: no Start button")
    }

    func testARoutineThatCameWithTheAppSaysSo() {
        // A new plan held Wake, Commute, Focus and Wind down, and tapping one said "Not set".
        let starter = RoutineWording.sheetFooter(sourceLabel: "Not set")
        XCTAssertTrue(starter.contains("starter routine"))
        XCTAssertTrue(starter.contains("Routines"), "it has to say where to change it")
        XCTAssertEqual(RoutineWording.sheetFooter(sourceLabel: "Next from your shows"), "Next from your shows")
    }
}
