import XCTest

/// Which domain Gmail itself vouched for (MAIL-ENGINE 10.6).
///
/// "Always show pictures from this sender" is keyed on this, so the failure to guard against is
/// the one where a sender gets to say who they are: a header written by the sender, a comment
/// that holds the words the reader looks for, a result that is not `pass`, a parent domain in
/// the wrong direction, a header of another server above Gmail's. Each is a test.
///
/// **The `Authentication-Results` headers here are written by hand from the shape RFC 8601
/// gives and the one Gmail is believed to write; none was copied from a real message.**
final class MailAuthRulesTests: XCTestCase {

    private func domain(_ headers: [(String, String)], from: String = "example.com") -> String? {
        MailAuthRules.authenticatedDomain(headers: headers, fromDomain: from)
    }

    private func google(_ results: String) -> (String, String) {
        ("Authentication-Results", "mx.google.com; " + results)
    }

    // MARK: - The three rules, in order

    /// Rule 1: Gmail's own DMARC pass for the From domain. The answer is the From domain, which
    /// is what lets a message through whose DKIM signer is a parent the reader cannot name.
    func testADMARCPassForTheFromDomainAuthenticatesIt() {
        XCTAssertEqual(domain([google("dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com")]),
                       "example.com")
        XCTAssertEqual(domain([google("dmarc=pass header.from=mail.example.com")], from: "mail.example.com"),
                       "mail.example.com")
    }

    func testADMARCPassForAnotherDomainOrAFailOrNoDomainAuthenticatesNothing() {
        XCTAssertNil(domain([google("dmarc=pass header.from=evil.example")]))
        XCTAssertNil(domain([google("dmarc=pass header.from=example.com.evil.example")]))
        XCTAssertNil(domain([google("dmarc=pass header.from=mail.example.com")], from: "example.com"),
                     "DMARC names the From domain exactly: a subdomain is not the parent")
        XCTAssertNil(domain([google("dmarc=pass header.from=example.com")], from: "mail.example.com"),
                     "and the From domain is exactly what it names")
        for verdict in ["fail", "none", "temperror", "permerror", "policy", "PASSED", ""] {
            XCTAssertNil(domain([google("dmarc=\(verdict) header.from=example.com")]), verdict)
        }
        XCTAssertNil(domain([google("dmarc=pass")]))
    }

    /// Rule 2, by `header.d`.
    func testADKIMPassByTheSigningDomainAuthenticatesItsDomain() {
        XCTAssertEqual(domain([google("dkim=pass header.d=example.com header.s=sel1")]), "example.com")
    }

    /// Rule 2, by `header.i` when there is no `header.d`: which one Gmail writes is not verified,
    /// and the believed one is `header.i=@domain`.
    func testADKIMPassByTheDomainOfTheIdentityAuthenticatesItWhenThereIsNoSigningDomain() {
        XCTAssertEqual(domain([google("dkim=pass header.i=@example.com header.s=sel header.b=abc")]), "example.com")
        XCTAssertEqual(domain([google("dkim=pass header.i=bob@example.com")]), "example.com",
                       "the domain is what follows the last @")
        XCTAssertEqual(domain([google("dkim=pass header.i=@mail.example.com")], from: "mail.example.com"),
                       "mail.example.com")
    }

    func testTheSigningDomainIsUsedWhenBothArePresentAndTheIdentityOnlyWhenThereIsNone() {
        XCTAssertNil(domain([google("dkim=pass header.d=esp.example header.i=@example.com")]),
                     "header.d is the signer; header.i is not asked when the result carries it")
        XCTAssertEqual(domain([google("dkim=pass header.d=example.com header.i=@news.example.org")]),
                       "example.com")
    }

    func testTheLastAtSignOfTheIdentityIsTheOneThatCounts() {
        // A local part the sender wrote, in a header Gmail may not have escaped: the domain is
        // what follows the last @, so text before it cannot be taken for one.
        XCTAssertNil(domain([google("dkim=pass header.i=@example.com@evil.example")]))
        XCTAssertNil(domain([google("dkim=pass header.i=example.com")]), "no @, no identity domain")
        XCTAssertNil(domain([google("dkim=pass header.i=")]))
    }

    /// A signer may sign for a subdomain of its own domain: `i=@mail.example.com` under
    /// `d=example.com`. Rule 2 on `i` alone reads the subdomain, which speaks for a From at
    /// that subdomain and not at the parent; rule 1 is what catches the parent.
    func testAnIdentityAtASubdomainDoesNotSpeakForTheParentButDMARCDoes() {
        XCTAssertNil(domain([google("dkim=pass header.i=@mail.example.com")], from: "example.com"))
        XCTAssertEqual(domain([google("dkim=pass header.i=@mail.example.com; dmarc=pass header.from=example.com")]),
                       "example.com")
    }

    /// Rule 3.
    func testAnSPFPassForTheFromDomainAuthenticatesItWhenThereIsNoDKIM() {
        XCTAssertEqual(domain([google("spf=pass (google.com: domain of bob@example.com designates 192.0.2.1 as permitted sender) smtp.mailfrom=bob@example.com")]),
                       "example.com")
        XCTAssertEqual(domain([google("spf=pass smtp.mailfrom=example.com")]), "example.com",
                       "a mailfrom with no local part is a domain")
        XCTAssertEqual(domain([google("spf=pass smtp.mailfrom=a@b@example.com")]), "example.com")
    }

    func testTheOrderIsDMARCThenDKIMThenSPFWhateverOrderGmailWroteThem() {
        // All three speak for the From domain but name different things; the first rule wins.
        XCTAssertEqual(
            domain([google("spf=pass smtp.mailfrom=bob@mail.example.com; dkim=pass header.d=example.com; dmarc=pass header.from=mail.example.com")],
                   from: "mail.example.com"),
            "mail.example.com", "DMARC first, and its answer is the From domain")
        XCTAssertEqual(
            domain([google("spf=pass smtp.mailfrom=bob@mail.example.com; dkim=pass header.d=example.com")],
                   from: "mail.example.com"),
            "example.com", "then DKIM, before SPF")
        XCTAssertEqual(
            domain([google("dkim=pass header.d=esp.example; spf=pass smtp.mailfrom=bob@example.com")]),
            "example.com", "and SPF when DKIM spoke for someone else")
    }

    /// A DKIM pass by a mailing service's domain does not speak for the From line.
    func testADKIMPassByAMailingServiceDoesNotSpeakForTheFromLine() {
        XCTAssertNil(domain([google("dkim=pass header.d=mailer.net header.s=a; spf=pass smtp.mailfrom=bounce@mailer.net")]))
        XCTAssertNil(domain([google("dkim=pass header.i=@mailer.net")]))
    }

    func testTheFirstAlignedDKIMResultIsTheOneReturned() {
        XCTAssertEqual(
            domain([google("dkim=pass header.d=esp.example header.s=a; dkim=pass header.d=example.com header.s=b")],
                   from: "mail.example.com"),
            "example.com", "the second signature is aligned, the first is the mailing service's")
    }

    /// Gmail's own shape, with everything it writes.
    func testAFullGmailStyleHeaderIsReadThroughItsCommentsAndOtherResults() {
        let value = "mx.google.com; "
            + "dkim=pass header.i=@other.example header.s=sel header.b=abc123; "
            + "spf=pass (google.com: domain of bob@example.com designates 192.0.2.1 as permitted sender) smtp.mailfrom=bob@example.com; "
            + "dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com"
        XCTAssertEqual(domain([("Authentication-Results", value)]), "example.com")
    }

    // MARK: - Alignment

    func testAParentOfTheFromDomainAuthenticatesItAndNotTheOtherWayRound() {
        XCTAssertEqual(domain([google("dkim=pass header.d=example.com")], from: "mail.example.com"), "example.com")
        XCTAssertNil(domain([google("dkim=pass header.d=mail.example.com")], from: "example.com"),
                     "a signature for a subdomain says nothing of the parent")
    }

    func testAnotherDomainAuthenticatesNothingAndNeitherDoesALookAlikeSuffix() {
        XCTAssertNil(domain([google("dkim=pass header.d=mailer.net")]))
        XCTAssertNil(domain([google("dkim=pass header.d=ample.com")], from: "example.com"),
                     "a parent is a parent on a dot boundary only")
        XCTAssertNil(domain([google("spf=pass smtp.mailfrom=bob@evilexample.com")], from: "example.com"))
    }

    func testAOneLabelNameIsNeverASigningDomain() {
        XCTAssertNil(domain([google("dkim=pass header.d=com")], from: "example.com"))
        XCTAssertNil(domain([google("dkim=pass header.d=.com")], from: "example.com"))
        XCTAssertNil(domain([google("dkim=pass header.d=a..com")], from: "x.a..com"))
    }

    func testCaseAndATrailingDotAreIgnoredOnBothSides() {
        XCTAssertEqual(domain([google("dkim=pass header.d=EXAMPLE.COM.")], from: "Mail.Example.Com."), "example.com")
        XCTAssertEqual(domain([google("DKIM=PASS HEADER.D=example.com")]), "example.com")
    }

    func testAFromDomainThatIsEmptyOrAnAuthenticatedNameThatIsNotADomainGivesNothing() {
        XCTAssertNil(domain([google("dkim=pass header.d=example.com")], from: ""))
        XCTAssertNil(domain([google("dkim=pass header.d=exam!ple.com")], from: "exam!ple.com"))
        XCTAssertNil(domain([google("dkim=pass header.d=exa mple.com")], from: "example.com"))
    }

    // MARK: - Only a pass counts

    func testAnythingButPassAuthenticatesNothing() {
        for verdict in ["fail", "neutral", "none", "softfail", "temperror", "permerror", "policy", "PASSED", ""] {
            XCTAssertNil(domain([google("dkim=\(verdict) header.d=example.com")]), "dkim=\(verdict)")
            XCTAssertNil(domain([google("spf=\(verdict) smtp.mailfrom=bob@example.com")]), "spf=\(verdict)")
        }
    }

    func testOtherMethodsAuthenticateNothing() {
        XCTAssertNil(domain([google("arc=pass header.d=example.com")]))
        XCTAssertNil(domain([google("auth=pass header.d=example.com")]))
    }

    func testAPassWithNoDomainOnItAuthenticatesNothing() {
        XCTAssertNil(domain([google("dkim=pass")]))
        XCTAssertNil(domain([google("spf=pass")]))
        XCTAssertNil(domain([google("dkim=pass header.s=sel only")]))
    }

    // MARK: - Whose header it is: the first, and only if it is Gmail's (MAJOR 4)

    /// `Authentication-Results` written by the sender below the one Gmail added on receipt.
    func testAHeaderTheSenderWroteBelowGmailsOwnIsIgnored() {
        let headers = [google("dkim=fail header.d=example.com; spf=fail smtp.mailfrom=bob@example.com; dmarc=fail header.from=example.com"),
                       ("Received", "from relay.example.net"),
                       google("dkim=pass header.d=example.com; spf=pass smtp.mailfrom=bob@example.com; dmarc=pass header.from=example.com")]
        XCTAssertNil(domain(headers), "Gmail said fail; the sender's pass is not evidence")
    }

    func testAHeaderFromAnotherServerIsNotGmails() {
        XCTAssertNil(domain([("Authentication-Results", "evil.example; dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([("Authentication-Results", "mx.google.com.evil.example; dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([("Authentication-Results", "xmx.google.com; dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([("Authentication-Results", "google.com; dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([("Authentication-Results", "dkim=pass header.d=example.com")]),
                     "with no authserv-id the first word is the method")
    }

    /// The reader does not look past another server's header for one that says it is Google's.
    /// Where another server's header is on top, Gmail wrote none, and what sits below is what
    /// the sender wrote, whatever it says. (This test once pinned the opposite.)
    func testAHeaderOfAnotherServerAboveOneThatClaimsToBeGoogleMeansNothingIsAuthenticated() {
        let forged = [("Authentication-Results", "mx.other-provider.example; dkim=fail header.d=example.com"),
                      google("dmarc=pass header.from=example.com; dkim=pass header.d=example.com")]
        XCTAssertNil(domain(forged), "the first is another server's: Gmail wrote none")
        XCTAssertNil(domain([("Authentication-Results", "evil.example; dkim=pass header.d=other.net"),
                             google("dkim=pass header.d=example.com")]))
    }

    func testOnlyTheFirstAuthenticationResultsCountsAndASecondIsIgnoredWhateverItSays() {
        // The first is Gmail's and authenticates nothing for this From; the second would.
        XCTAssertNil(domain([google("dkim=pass header.d=other.net"),
                             google("dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([google("spf=fail smtp.mailfrom=bob@example.com"),
                             ("Authentication-Results", "mx.google.com; dmarc=pass header.from=example.com")]))
        // And with the real one first, it is read.
        XCTAssertEqual(domain([google("dkim=pass header.d=example.com"),
                               google("dkim=fail header.d=example.com")]), "example.com")
    }

    func testTheServerIdIsMatchedWithoutRegardToCaseAndMayHaveAVersion() {
        XCTAssertEqual(domain([("Authentication-Results", "MX.Google.COM; dkim=pass header.d=example.com")]), "example.com")
        XCTAssertEqual(domain([("Authentication-Results", "mx.google.com 1; dkim=pass header.d=example.com")]), "example.com")
        XCTAssertEqual(domain([("authentication-results", "mx.google.com; dkim=pass header.d=example.com")]), "example.com")
        XCTAssertEqual(domain([("AUTHENTICATION-RESULTS", "mx.google.com; dkim=pass header.d=example.com")]), "example.com")
        XCTAssertEqual(domain([("Authentication-Results", "(Gmail) mx.google.com; dkim=pass header.d=example.com")]), "example.com",
                       "comments aside")
    }

    func testARCResultsAreNotThisHeader() {
        XCTAssertNil(domain([("ARC-Authentication-Results", "i=1; mx.google.com; dkim=pass header.d=example.com")]))
        XCTAssertNil(domain([("X-Authentication-Results", "mx.google.com; dkim=pass header.d=example.com")]))
        // And an ARC header above Gmail's own is not "the first Authentication-Results".
        XCTAssertEqual(domain([("ARC-Authentication-Results", "i=1; mx.other.example; dkim=fail"),
                               google("dkim=pass header.d=example.com")]), "example.com")
    }

    func testNoHeadersAtAllAuthenticateNothing() {
        XCTAssertNil(domain([]))
        XCTAssertNil(domain([("From", "bob@example.com"), ("Subject", "x")]))
    }

    // MARK: - Folded and cut

    func testAFoldedHeaderIsOneHeaderAndIsRead() {
        XCTAssertEqual(domain([("Authentication-Results", "mx.google.com;\r\n dkim=pass\r\n header.d=example.com")]), "example.com")
        XCTAssertEqual(domain([("Authentication-Results", "mx.google.com;\n\tdmarc=pass\n\theader.from=example.com")]), "example.com")
    }

    /// A header cut at the value limit is not read: a sender can lengthen what Gmail writes there,
    /// and a result cut away is unknown, not absent.
    func testACutAuthenticationHeaderIsNotRead() {
        let padding = String(repeating: "x", count: MessageHeaders.maxValueBytes)
        let value = "mx.google.com; dkim=pass header.d=example.com; " + padding
        let headers = MessageHeaders([("Authentication-Results", value), ("From", "Bob <bob@example.com>")])
        XCTAssertEqual(headers.field("Authentication-Results")?.wasCut, true)
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: headers, fromDomain: "example.com"))
        // As pairs, a value of the limit or more is taken to have been cut.
        XCTAssertNil(domain([("Authentication-Results", value)]))
        // And one that fits is read.
        XCTAssertEqual(MailAuthRules.authenticatedDomain(
            headers: MessageHeaders([("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com")]),
            fromDomain: "example.com"), "example.com")
    }

    /// The first one is the one that counts: if it is cut, a second that fits is not a first.
    func testACutFirstHeaderIsNotReplacedByASecond() {
        let long = "mx.google.com; spf=fail; " + String(repeating: "y", count: MessageHeaders.maxValueBytes)
        let headers = MessageHeaders([("Authentication-Results", long),
                                      ("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com")])
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: headers, fromDomain: "example.com"))
    }

    /// `Authentication-Results` is never among the headers looked for past the cut (5.6): its
    /// meaning is its position.
    func testAnAuthenticationResultsHeaderPastTheLineLimitIsNotKept() {
        let padding = (0..<MessageHeaders.maxLines).map { ("Received", "hop \($0)") }
        let headers = MessageHeaders(padding + [("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com")])
        XCTAssertNil(headers.field("Authentication-Results"))
        XCTAssertFalse(headers.isComplete)
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: headers, fromDomain: "example.com"))
    }

    // MARK: - Text that is not part of a result

    /// The words the reader looks for, inside a comment, are not results.
    func testACommentCannotHoldAResult() {
        XCTAssertNil(domain([google("dkim=fail (dkim=pass header.d=example.com) header.d=other.net")]))
        XCTAssertNil(domain([google("dkim=pass (header.d=example.com)")]))
        XCTAssertEqual(domain([google("dkim=pass (bad; header.d=evil.example) header.d=example.com")]), "example.com",
                       "a semicolon in a comment does not cut the result in two")
        XCTAssertEqual(domain([google("dkim=pass (a (nested (deep)) comment) header.d=example.com")]), "example.com")
        XCTAssertNil(domain([google("dkim=fail (x) ; (dmarc=pass header.from=example.com)")]))
    }

    func testAQuotedValueIsReadAndASemicolonInQuotesDoesNotSplit() {
        XCTAssertEqual(domain([google(#"dkim=pass header.d="example.com""#)]), "example.com")
        XCTAssertNil(domain([google(#"dkim=fail reason="x; dkim=pass header.d=example.com""#)]))
    }

    func testSpacesAroundTheEqualsSignAreAllowed() {
        XCTAssertEqual(domain([google("dkim = pass header.d = example.com")]), "example.com")
        XCTAssertEqual(domain([google("spf =pass smtp.mailfrom= bob@example.com")]), "example.com")
    }

    func testAnUnbalancedParenthesisOnlyDropsWhatFollowsIt() {
        XCTAssertNil(domain([google("dkim=pass (oops header.d=example.com")]))
        XCTAssertEqual(domain([google("dkim=pass header.d=example.com (oops")]), "example.com")
        XCTAssertNil(domain([google(#"dkim=pass header.d="example.com"#)]),
                     "a quote that never closes is not a value the reader is sure of")
    }

    // MARK: - Gmail's DMARC result and the sender

    func testGmailsDMARCResultAgreesWhenItNamesTheSameDomainWhateverTheVerdict() {
        func agrees(_ value: String, _ domain: String) -> Bool {
            MailAuthRules.dmarcAgrees(headers: MessageHeaders([("Authentication-Results", value)]), with: domain)
        }
        XCTAssertTrue(agrees("mx.google.com; dmarc=pass header.from=example.com", "example.com"))
        XCTAssertTrue(agrees("mx.google.com; dmarc=fail header.from=Example.COM.", "example.com"))
        XCTAssertFalse(agrees("mx.google.com; dmarc=pass header.from=evil.example", "example.com"))
        XCTAssertFalse(agrees("mx.google.com; dmarc=pass header.from=mail.example.com", "example.com"))
        XCTAssertFalse(agrees("mx.google.com; dmarc=pass", "example.com"), "a DMARC result naming no domain agrees with none")
        XCTAssertFalse(agrees("mx.google.com; dmarc=none header.from=a.example; dmarc=pass header.from=example.com", "example.com"),
                       "every DMARC result must name it")
    }

    func testThereIsNothingToDisagreeWithWhenGmailWroteNoDMARCResultOrNoHeader() {
        XCTAssertTrue(MailAuthRules.dmarcAgrees(headers: MessageHeaders([("From", "x@example.com")]), with: "example.com"))
        XCTAssertTrue(MailAuthRules.dmarcAgrees(
            headers: MessageHeaders([("Authentication-Results", "mx.google.com; spf=pass smtp.mailfrom=x@example.com")]),
            with: "example.com"))
        // Another server's header is not Gmail's, and says nothing about what Gmail read.
        XCTAssertTrue(MailAuthRules.dmarcAgrees(
            headers: MessageHeaders([("Authentication-Results", "mx.other.example; dmarc=pass header.from=evil.example")]),
            with: "example.com"))
    }

    func testAGmailHeaderThatWasCutCannotBeReadAndIsNotAgreement() {
        let long = "mx.google.com; dmarc=pass header.from=example.com; " + String(repeating: "z", count: MessageHeaders.maxValueBytes)
        XCTAssertFalse(MailAuthRules.dmarcAgrees(headers: MessageHeaders([("Authentication-Results", long)]), with: "example.com"))
    }

    // MARK: - The headers of a message

    func testTheMessageHeadersOverloadReadsTheSameHeader() {
        let headers = MessageHeaders([("Received", "x"), google("dkim=pass header.d=example.com"), ("From", "a@example.com")])
        XCTAssertEqual(MailAuthRules.authenticatedDomain(headers: headers, fromDomain: "example.com"), "example.com")
    }

    func testAnUnauthenticatedFixtureAsksEveryTime() {
        let failing = [google("dkim=fail header.d=example.com; spf=softfail smtp.mailfrom=bob@example.com; dmarc=fail header.from=example.com")]
        XCTAssertNil(domain(failing), "no authenticated domain: 'always from this sender' is not offered")
    }

    // MARK: - The forged-below fixture

    func testTheForgedHeaderFixtureAuthenticatesNobody() throws {
        let message = try MailHostileMessages.decode(MailHostileMessages.authResultsForgedBelowOtherServer)
        let headers = MessageHeaders(payload: message.payload)
        XCTAssertEqual(headers.values("Authentication-Results").count, 2)
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: headers, fromDomain: "victim.example"))
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: headers.pairs, fromDomain: "victim.example"))
    }
}
