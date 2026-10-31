import XCTest

final class NotificationWritesTests: XCTestCase {
    /// A remove and the add after it reach the system in that order, and neither is run on
    /// the thread that asked (the main thread waited on the system's daemon, and froze).
    func testWritesRunInOrderAndOffTheMainThread() {
        let done = expectation(description: "the writes ran")
        let lock = NSLock()
        var order: [Int] = []
        var onMain = false
        for step in 0..<50 {
            NotificationWrites.perform {
                lock.lock()
                order.append(step)
                if Thread.isMainThread { onMain = true }
                lock.unlock()
                if step == 49 { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order, Array(0..<50))
        XCTAssertFalse(onMain)
    }
}
