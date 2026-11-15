import XCTest

final class MailVerificationCodeTests: XCTestCase {
    private func body(_ lines: String...) -> MailBody {
        .text(MailText(blocks: lines.map { MailTextBlock(kind: .paragraph, runs: [.init(text: $0)]) }), quoteStartsAt: nil, notices: [])
    }
    func testExplicitCodesBeforeAndAfterLabelsPreserveLeadingZeros() {
        for line in ["Your verification code is: 042819", "042819 is your verification code", "One-Time Verification Code: 042819", "OTP: 042819", "Security code 042819", "Password reset code: 042819", "Log in code: 042819"] {
            XCTAssertEqual(MailVerificationCode.extract(subject: "Account", body: body(line)), "042819", line)
        }
    }
    func testSubjectLabelAndIsolatedCodeWorkWithoutMatchingTheBrand() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "Your one-time verification code", body: body("Code requested", "042819", "Do not share this code.")), "042819")
        XCTAssertEqual(MailVerificationCode.extract(subject: "Verification code: 042819", body: .notOnDevice), "042819")
    }
    func testAThreadSubjectCannotContributeAnOlderCodeButCanDescribeTheCurrentBody() {
        XCTAssertNil(MailVerificationCode.extract(subject: "Verification code: 042819", body: body("Thanks"), allowSubjectCode: false))
        XCTAssertEqual(MailVerificationCode.extract(subject: "Verification code: 042819", body: body("Your code is 819042"), allowSubjectCode: false), "819042")
    }
    func testGenericCodeLabelRequiresAnAuthenticationSubject() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "Your verification code", body: body("Your code is 042819")), "042819")
        XCTAssertNil(MailVerificationCode.extract(subject: "Order receipt", body: body("Your code is 042819")))
    }
    func testGroupedDigitsAndMixedCodesKeepTheirMeaning() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "Sign-in", body: body("Verification code: 042 819")), "042819")
        XCTAssertEqual(MailVerificationCode.extract(subject: "Sign-in", body: body("Verification code: aB1cD2")), "aB1cD2")
        XCTAssertEqual(MailVerificationCode.extract(subject: "Sign-in", body: body("Verification code: ABCD-EFGH")), "ABCD-EFGH")
    }
    func testNearbyExpiryNumbersAreNotAppendedToTheCode() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "Sign-in", body: body("Verification code: 042819 10 minutes remaining")), "042819")
        XCTAssertNil(MailVerificationCode.extract(subject: "Sign-in", body: body("Verification code: 2026-11-15")))
        XCTAssertNil(MailVerificationCode.extract(subject: "Sign-in", body: body("Security code: 1234.56")))
    }
    func testDuplicatesAreOneCodeButDifferentCodesAreAmbiguous() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "Verification code: 042819", body: body("Verification code: 042819")), "042819")
        XCTAssertNil(MailVerificationCode.extract(subject: "Verification code: 042819", body: body("Verification code: 819042")))
    }
    func testOrdersPhonesDatesLinksAndGenericCodesAreNotAuthenticationCodes() {
        for line in ["Order code: 042819", "Call 0428191234", "Your order is 042819", "https://plan.example/verify?code=042819", "Your verification code expires on 2026-11-15", "Security code: support", "Verification code: 123456789012"] {
            XCTAssertNil(MailVerificationCode.extract(subject: "Account notice", body: body(line)), line)
        }
    }
    func testQuotedAndForwardedCodesAreNotPromoted() {
        let text = MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Thanks")]), .init(kind: .quote(depth: 1), runs: [.init(text: "Verification code: 042819")])])
        XCTAssertNil(MailVerificationCode.extract(subject: "Re: Verification code", body: .text(text, quoteStartsAt: 1, notices: [])))
        XCTAssertNil(MailVerificationCode.extract(subject: "Fwd: Verification code", body: body("Verification code: 042819")))
        XCTAssertNil(MailVerificationCode.extract(subject: "Verification code", body: body("> Verification code: 042819")))
    }
    func testPreparedDesignedMailUsesVisiblePlainTextWithoutParsingHTML() {
        let plain = MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])])
        XCTAssertEqual(MailVerificationCode.extract(subject: "Sign-in", body: .designed(document: "<img src='https://plan.example/819042'>", pictures: .init(boxes: [], waiting: 0, trackersRemoved: 0), hasQuote: false, plain: plain, notices: [])), "042819")
    }
    func testEmptyBlocksAndRunsCannotBypassTheWorkBudget() {
        let code = MailTextBlock(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])
        let emptyBlocks = Array(repeating: MailTextBlock(kind: .paragraph, runs: []), count: MailVerificationCode.maximumBlocks)
        XCTAssertNil(MailVerificationCode.extract(subject: "Account", body: .text(MailText(blocks: emptyBlocks + [code]), quoteStartsAt: nil, notices: [])))
        let emptyRuns = Array(repeating: MailTextRun(text: ""), count: MailVerificationCode.maximumRuns)
        XCTAssertNil(MailVerificationCode.extract(subject: "Account", body: .text(MailText(blocks: [.init(kind: .paragraph, runs: emptyRuns)] + [code]), quoteStartsAt: nil, notices: [])))
    }
    func testLargeBodyWorkIsBounded() {
        XCTAssertNil(MailVerificationCode.extract(subject: "Account", body: body(String(repeating: "x", count: MailVerificationCode.maximumCharacters), "Verification code: 042819")))
    }
    func testAuthenticationInstructionsAllowCodesAfterMetadataAndInDifferentFormats() {
        let examples: [(String, [String], String)] = [
            ("Your verification code - expires in 15 minutes", ["Hello Noor", "Use the verification code below to complete your action", "04281973", "The code expires in 15 minutes", "Support", "100 Main Street", "City 10001"], "04281973"),
            ("Account verification code", ["Sign-in attempt", "Date: 2026-11-15", "Account: Noor", "Location: US", "IP: 192.0.2.10", "Enter this 6 digit code on the sign in page to confirm your identity:", "042819"], "042819"),
            ("Your account code is 042819", ["Enter this temporary verification code to continue:", "042819"], "042819"),
            ("042819 is your account code", ["Confirm your account", "Enter this code:", "042819"], "042819"),
            ("Your code: 042819", ["Copy and paste the code below to log in to your account", "042819"], "042819"),
            ("Confirmation code: A7K-Q2M", ["Confirm your email address", "Here is your confirmation code", "A7K-Q2M"], "A7K-Q2M"),
            ("RAVON is your account verification code", ["Here is a 5-character verification code for verifying your email address", "RAVON"], "RAVON"),
            ("Your one time PIN: 042819", ["Use the code below to access your account", "042819"], "042819"),
            ("Your activation code", ["You can now log in using the code below", "A1b2C3"], "A1b2C3"),
            ("Your sign-in code", ["Confirm it is you signing in", "Enter the code below", "042 819"], "042819"),
            ("Confirmation code", ["To finish logging in, enter this code:", "042819"], "042819"),
            ("Your code: 042819", ["Use the code below to verify your account", "042819"], "042819"),
            ("Account OTP", ["The OTP code is: 042819"], "042819"),
            ("Verify your identity", ["Here is your temporary code: 042819"], "042819"),
            ("Verification code for your request", ["Please verify your email address by entering the following code: 042819."], "042819")
        ]
        for (subject, lines, expected) in examples {
            let message = MailBody.text(MailText(blocks: lines.map { .init(kind: .paragraph, runs: [.init(text: $0)]) }), quoteStartsAt: nil, notices: [])
            XCTAssertEqual(MailVerificationCode.extract(subject: subject, body: message), expected, subject)
        }
    }

    func testMeetingDeckAndOfferPasscodesAreNotOneTimeAuthenticationCodes() {
        for (subject, text) in [
            ("Meeting invitation", "Join the meeting now\nMeeting ID: 123 456 789\nPasscode: 042819"),
            ("Investor deck", "Investor presentation\nPasscode: A1b2C3!"),
            ("Save on tickets", "Unlock this offer\nPasscode: 042819\nOffer valid through Thursday"),
            ("Webinar replay", "Join webinar\nPasscode: 042819"),
            ("Event registration", "Authentication code, when needed, will be sent by email\nMeeting ID: 123456789\nPasscode\n042819"),
            ("Special pricing", "Use the following referral code:\nA7KQ2M\nLog in to your account to apply it")
        ] {
            XCTAssertNil(MailVerificationCode.extract(subject: subject, body: body(text)), subject)
        }
    }

    func testLinkedActionsAreNotAlphabeticCodePayloads() {
        let text = MailText(blocks: [
            .init(kind: .paragraph, runs: [.init(text: "Your verification code")]),
            .init(kind: .paragraph, runs: [.init(text: "VERIFY", link: URL(string: "https://plan.example/verify"))])
        ])
        XCTAssertNil(MailVerificationCode.extract(subject: "Verify your account", body: .text(text, quoteStartsAt: nil, notices: [])))
    }

    func testSmallPrintCanContainTheActualAuthenticationInstructions() {
        let text = MailText(blocks: [
            .init(kind: .fineprint, runs: [.init(text: "Please enter the following code for verification:")]),
            .init(kind: .fineprint, runs: [.init(text: "042819")]),
            .init(kind: .fineprint, runs: [.init(text: "100 Main Street, City 10001")])
        ])
        XCTAssertEqual(MailVerificationCode.extract(subject: "One-time verification code", body: .text(text, quoteStartsAt: nil, notices: [])), "042819")
    }

    func testPreparationComponentCost() throws {
        let cases: [(String, String, MailBody, String?)] = [
            ("short-code", "Account", body("Verification code: 042819"), "042819"),
            ("bounded-negative", "Account", body(String(repeating: "Ordinary message. ", count: 1200)), nil),
            ("repeated-labels", "Account", body(String(repeating: "Verification code is unavailable. ", count: 600)), nil),
            ("bounded-blocks", "Account", .text(MailText(blocks: (0..<2000).map { _ in .init(kind: .paragraph, runs: []) }), quoteStartsAt: nil, notices: []), nil),
            ("mixed-code", "Sign-in", body("Verification code: Ab1cD2"), "Ab1cD2")
        ]
        var samples: [[String: Any]] = []
        for trial in 0..<7 {
            for (name, subject, message, expected) in cases {
                let start = DispatchTime.now().uptimeNanoseconds
                let found = MailVerificationCode.extract(subject: subject, body: message)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                XCTAssertEqual(found, expected, name)
                samples.append(["case": name, "trial": trial, "milliseconds": ms])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["scope": "Native text extraction only; OS/regex caches uncontrolled. Not UI frame or input acceptance.", "samples": samples], options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "verification-code-component-samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
