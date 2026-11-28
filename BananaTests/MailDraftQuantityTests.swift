#if !BANANA_PUBLIC
import XCTest

final class MailDraftQuantityTests: XCTestCase {
    private func validate(_ reply: String, from source: String) throws {
        try MailDraftPrompt.checkGrounding(in: reply, suppliedText: source, authorInstruction: "Draft a reply.")
    }

    func testQuantitiesCanUseEquivalentUnits() throws {
        try validate("The sleeve measures 125 millimetres.", from: "The sleeve is 12.5 cm long.")
        try validate("Allow 90 minutes.", from: "Allow 1.5 hours.")
        try validate("The kit contains 750 mL and weighs 1 kg.", from: "Volume 0.75 litres. Weight 1000 grams.")
        try validate("Use under 10 cm.", from: "Use under 100 mm.")
    }

    func testEveryDimensionAndValueMustBePresent() {
        for source in ["There are ten sleeves.", "There are 10 sleeves.", "Each sleeve weighs 10 g.",
                       "Width is 10 mm.", "The product code is X10cm.", "Each fits under 10 cm.",
                       "The range is 8 cm to 10 cm.", "Each has area 10 cm².", "The rate is 10 cm/s."] {
            XCTAssertThrowsError(try validate("The sleeve measures 10 cm.", from: source), source)
        }
        XCTAssertThrowsError(try validate("The kit contains 750 mL and weighs 1 kg.", from: "Volume 750 mL."))
        XCTAssertThrowsError(try validate("The length is 10 metres.", from: "The budget is $10M."))
        XCTAssertThrowsError(try validate("They weigh 3 g.", from: "The terminal uses a 3G connection."))
    }
}
#endif
