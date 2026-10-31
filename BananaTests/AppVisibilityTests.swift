import XCTest

/// Backgrounding must stop the work immediately but keep drawing for a beat.
///
/// The drawing gate exists because the tree kept re-rendering in a pocket until iOS killed the
/// process for exceeding the background CPU budget. Blanking the instant the app backgrounded
/// fixed that and broke something else: iOS takes the app-switcher snapshot *after* backgrounding,
/// so it photographed the blank, and the app appeared as a black rectangle when swiping between
/// apps. These tests pin both halves so neither fix can quietly undo the other.
@MainActor
final class AppVisibilityTests: XCTestCase {

    private var originalGrace: TimeInterval = 0

    override func setUp() {
        super.setUp()
        originalGrace = AppVisibility.snapshotGrace
        AppVisibility.snapshotGrace = 0.05
    }

    override func tearDown() {
        AppVisibility.snapshotGrace = originalGrace
        super.tearDown()
    }

    func testWorkStopsImmediatelyOnBackground() {
        let visibility = AppVisibility()
        visibility.set(active: false)
        XCTAssertFalse(visibility.isActive, "write-back and re-planning must not run in a pocket")
    }

    func testDrawingContinuesBrieflyAfterBackgrounding() {
        let visibility = AppVisibility()
        visibility.set(active: false)
        XCTAssertTrue(visibility.rendersContent,
                      "the tree must still draw so iOS photographs the real screen, not a blank")
    }

    func testDrawingStopsOnceTheGraceElapses() async throws {
        let visibility = AppVisibility()
        visibility.set(active: false)
        try await Task.sleep(for: .seconds(AppVisibility.snapshotGrace * 6))
        XCTAssertFalse(visibility.rendersContent, "the pocket case still has to stop rendering")
    }

    /// The regression that would be easiest to introduce: coming straight back and having the
    /// queued blanking fire over a screen already in front of the user.
    func testReturningBeforeTheGraceElapsesCancelsTheBlank() async throws {
        let visibility = AppVisibility()
        visibility.set(active: false)
        visibility.set(active: true)
        try await Task.sleep(for: .seconds(AppVisibility.snapshotGrace * 6))
        XCTAssertTrue(visibility.rendersContent, "a queued blank must not fire after returning")
        XCTAssertTrue(visibility.isActive)
    }

    func testReturningAfterBlankingRestoresDrawing() async throws {
        let visibility = AppVisibility()
        visibility.set(active: false)
        try await Task.sleep(for: .seconds(AppVisibility.snapshotGrace * 6))
        XCTAssertFalse(visibility.rendersContent)
        visibility.set(active: true)
        XCTAssertTrue(visibility.rendersContent)
        XCTAssertTrue(visibility.isActive)
    }

    func testRepeatedBackgroundingDoesNotStackBlanks() async throws {
        let visibility = AppVisibility()
        visibility.set(active: false)
        visibility.set(active: false)
        visibility.set(active: true)
        try await Task.sleep(for: .seconds(AppVisibility.snapshotGrace * 6))
        XCTAssertTrue(visibility.rendersContent, "a second background must not leave a stray blank")
    }
}
