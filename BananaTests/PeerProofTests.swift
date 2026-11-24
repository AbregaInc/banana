import XCTest

/// The LAN peer proof (audit run-2): an answer to a challenge must never be the proof the
/// challenger accepts, whatever names the two sides take.
final class PeerProofTests: XCTestCase {
    private let nonce = Data(repeating: 7, count: 16)

    func testTheTwoDirectionsNeverSignTheSameBytes() {
        // What a device signs when it answers, against what it checks when it challenged.
        let answered = PeerProof.message(nonce: nonce, challenger: "Mallory", responder: "Noor's iPhone")
        let checked = PeerProof.message(nonce: nonce, challenger: "Noor's iPhone", responder: "Mallory")
        XCTAssertNotEqual(answered, checked)
    }

    func testNamesCannotBeSplitDifferentlyIntoTheSameBytes() {
        // Joined with a separator alone these two pairs spelled the same message.
        XCTAssertNotEqual(PeerProof.message(nonce: nonce, challenger: "a|b", responder: "c"),
                          PeerProof.message(nonce: nonce, challenger: "a", responder: "b|c"))
    }
}
