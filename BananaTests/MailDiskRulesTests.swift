import XCTest

/// The free-space floor (MAIL-ENGINE 11.3, invariant 26): when the fill must stop, when it may
/// go on, and when to look.
///
/// What the floor protects is the commit of a change he has just made, which is a few hundred
/// bytes and must always fit. The rule is the numbers, two comparisons and a memory of which one
/// to use, so each is pinned: both thresholds at, just under and just over; the boundary
/// (`free == floor` is ok); and that a fill is not let go at the floor itself, where its next
/// batch would stop it again.
final class MailDiskRulesTests: MailStoreTestCase {

    private let megabyte: Int64 = 1_048_576
    private let gigabyte: Int64 = 1_073_741_824

    // MARK: - The numbers

    func testTheFloorIsOneGibibyteOnAPhoneOrPadAndFiveOnAMac() {
        XCTAssertEqual(MailDiskRules.floor(for: .phone), 1 * gigabyte)
        XCTAssertEqual(MailDiskRules.floor(for: .pad), 1 * gigabyte)
        XCTAssertEqual(MailDiskRules.floor(for: .mac), 5 * gigabyte)
    }

    func testEvictionAimsForFiveHundredMebibytesAboveTheFloor() {
        let floor = MailDiskRules.floor(for: .phone)
        XCTAssertEqual(MailDiskRules.evictionTarget(floor: floor), floor + 500 * megabyte)
        XCTAssertEqual(MailDiskRules.evictionHeadroom, 500 * megabyte)
    }

    // MARK: - The first threshold: from ok

    func testFromOkItStopsOnlyWhenFreeSpaceIsStrictlyBelowTheFloor() {
        let floor = MailDiskRules.floor(for: .phone)
        XCTAssertEqual(MailDiskRules.state(free: floor - 1, floor: floor, was: .ok), .belowFloor, "just under")
        XCTAssertEqual(MailDiskRules.state(free: floor, floor: floor, was: .ok), .ok, "at the floor is ok")
        XCTAssertEqual(MailDiskRules.state(free: floor + 1, floor: floor, was: .ok), .ok, "just over")
        XCTAssertEqual(MailDiskRules.state(free: 0, floor: floor, was: .ok), .belowFloor)
        XCTAssertEqual(MailDiskRules.state(free: 100 * gigabyte, floor: floor, was: .ok), .ok)
    }

    // MARK: - The second threshold: from belowFloor

    func testFromBelowFloorItResumesOnlyAtTheFloorPlusFiveHundredMebibytes() {
        let floor = MailDiskRules.floor(for: .phone)
        let target = MailDiskRules.evictionTarget(floor: floor)
        XCTAssertEqual(MailDiskRules.state(free: target - 1, floor: floor, was: .belowFloor), .belowFloor, "just under")
        XCTAssertEqual(MailDiskRules.state(free: target, floor: floor, was: .belowFloor), .ok, "at the target it resumes")
        XCTAssertEqual(MailDiskRules.state(free: target + 1, floor: floor, was: .belowFloor), .ok, "just over")
    }

    func testAFillStoppedAtTheFloorIsNotLetGoAtTheFloorOrBetween() {
        let floor = MailDiskRules.floor(for: .mac)
        for free in [floor - 1, floor, floor + 1, floor + 250 * megabyte, floor + 500 * megabyte - 1] {
            XCTAssertEqual(MailDiskRules.state(free: free, floor: floor, was: .belowFloor), .belowFloor,
                           "free \(free - floor) bytes over the floor")
        }
    }

    func testTheSameFreeSpaceIsEnoughOnAPhoneAndNotOnAMac() {
        let free = 3 * gigabyte
        XCTAssertEqual(MailDiskRules.state(free: free, floor: MailDiskRules.floor(for: .phone), was: .ok), .ok)
        XCTAssertEqual(MailDiskRules.state(free: free, floor: MailDiskRules.floor(for: .mac), was: .ok), .belowFloor)
    }

    // MARK: - When to look

    func testFreeSpaceIsReadAtMostOnceAMinuteAndAfterEveryFiftyMebibytesWritten() {
        XCTAssertFalse(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 59.9, bytesWrittenSinceLastRead: 0))
        XCTAssertTrue(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 60, bytesWrittenSinceLastRead: 0))
        XCTAssertTrue(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 3_600, bytesWrittenSinceLastRead: 0))

        XCTAssertFalse(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 1, bytesWrittenSinceLastRead: 50 * megabyte - 1))
        XCTAssertTrue(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 1, bytesWrittenSinceLastRead: 50 * megabyte))
        XCTAssertTrue(MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: 0, bytesWrittenSinceLastRead: gigabyte))
    }

    // MARK: - The watch

    /// A watch on a manual clock whose free space is whatever the test says, and which counts
    /// how many times it was asked.
    private final class Rig: @unchecked Sendable {
        let clock = ManualMailClock()
        let floor = MailDiskRules.floor(for: .phone)
        private let lock = NSLock()
        private var free: Int64
        private var reads = 0
        init(free: Int64) { self.free = free }
        func set(free: Int64) { lock.lock(); self.free = free; lock.unlock() }
        var reading: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func makeWatch() -> MailDiskWatch {
            MailDiskWatch(floor: floor, clock: clock) { [self] in
                lock.lock(); defer { lock.unlock() }
                reads += 1
                return free
            }
        }
    }

    /// The watch is asked off the main thread, as the engine asks it: it reads the disk.
    private func state(_ watch: MailDiskWatch) async throws -> MailDiskState {
        try await offMain { watch.state() }
    }

    func testTheFirstQuestionLooksAndTheAnswerIsOkWhenThereIsRoom() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        XCTAssertEqual(rig.reading, 0, "nothing is read until it is asked")
        let answer1 = try await state(watch)
        XCTAssertEqual(answer1, .ok)
        XCTAssertEqual(rig.reading, 1)
    }

    func testItLooksAtMostOnceAMinute() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        _ = try await state(watch)
        for _ in 1...20 { _ = try await state(watch) }
        XCTAssertEqual(rig.reading, 1, "twenty more questions in the same instant")

        rig.clock.advance(by: 59)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 1, "59 seconds")

        rig.clock.advance(by: 1)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 2, "60 seconds")
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 2)
    }

    func testItLooksAgainAfterFiftyMebibytesAreReportedWrittenWhateverTheTime() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        _ = try await state(watch)

        watch.wrote(30 * megabyte)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 1, "30 MiB is not enough")
        watch.wrote(20 * megabyte - 1)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 1, "50 MiB less a byte")
        watch.wrote(1)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 2, "50 MiB")

        // The count starts again from each look.
        watch.wrote(10 * megabyte)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 2)
    }

    func testItStopsBelowTheFloorAndStaysStoppedBetweenTheFloorAndTheFloorPlusFiveHundredMebibytes() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        let answer2 = try await state(watch)
        XCTAssertEqual(answer2, .ok)

        rig.set(free: rig.floor - 1)
        rig.clock.advance(by: 60)
        let answer3 = try await state(watch)
        XCTAssertEqual(answer3, .belowFloor)

        // Eviction frees some space — back over the floor, not yet over the target.
        for freed in [0, 1, 250 * megabyte, 500 * megabyte - 1] as [Int64] {
            rig.set(free: rig.floor + freed)
            rig.clock.advance(by: 60)
            let answer4 = try await state(watch)
            XCTAssertEqual(answer4, .belowFloor, "\(freed) bytes over the floor: not let go")
        }

        rig.set(free: rig.floor + 500 * megabyte)
        rig.clock.advance(by: 60)
        let answer5 = try await state(watch)
        XCTAssertEqual(answer5, .ok, "at the floor plus 500 MiB it resumes")

        // And is stopped again only by going below the floor, not by falling back to the target.
        rig.set(free: rig.floor)
        rig.clock.advance(by: 60)
        let answer6 = try await state(watch)
        XCTAssertEqual(answer6, .ok, "free space equal to the floor is ok")
        rig.set(free: rig.floor - 1)
        rig.clock.advance(by: 60)
        let answer7 = try await state(watch)
        XCTAssertEqual(answer7, .belowFloor)
    }

    func testBetweenLooksTheWatchAnswersWhatItLastSaid() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        let answer8 = try await state(watch)
        XCTAssertEqual(answer8, .ok)
        rig.set(free: 0)                       // the disk fills — and nobody has looked yet
        let answer9 = try await state(watch)
        XCTAssertEqual(answer9, .ok, "it answers from its last look until it is time for another")
        rig.clock.advance(by: 60)
        let answer10 = try await state(watch)
        XCTAssertEqual(answer10, .belowFloor)
    }

    func testAClockSetBackDoesNotMakeItWaitAnHourLonger() async throws {
        let rig = Rig(free: 10 * gigabyte)
        let watch = rig.makeWatch()
        _ = try await state(watch)
        rig.clock.advance(by: -3_600)
        _ = try await state(watch)
        XCTAssertEqual(rig.reading, 2)
    }

    func testAskingTheWatchChecksThatItIsNotOnTheMainThread() {
        // The real check traps; a recorder stands in for it and is shown to be asked, here, on
        // the main thread, by `state()` and not by `wrote(_:)`, which does no I/O.
        let seen = MailTestList<String>()
        MailMainQueueGuard.replaceForTesting { seen.add("\($0) \(Thread.isMainThread ? "on main" : "off main")") }
        defer { MailMainQueueGuard.replaceForTesting(nil) }

        let watch = Rig(free: gigabyte).makeWatch()
        watch.wrote(1)
        XCTAssertEqual(seen.all, [])
        _ = watch.state()
        XCTAssertEqual(seen.all, ["MailDiskWatch.state on main"])
    }
}
