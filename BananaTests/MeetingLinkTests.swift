import XCTest

/// Picking the join link out of a meeting invite.
///
/// There were no tests here at all, which is how "the Join button opens an image" shipped. A real
/// invite is full of URLs on the meeting platform's own domain — a banner image, "Download Zoom",
/// "Test your audio" — and the old rule was "first branded host with any path wins", scanning in
/// document order. The banner sits at the top of most templates, so the banner won.
final class MeetingLinkTests: XCTestCase {

    /// The shape of a Zoom invite: branding image first, join link in the middle, help links after.
    private let zoomInvite = """
    <img src="https://us02web.zoom.us/static/94973/image/new/ZoomLogo.png" alt="Zoom">
    Sam is inviting you to a scheduled Zoom meeting.

    Join Zoom Meeting
    https://us02web.zoom.us/j/81234567890?pwd=Zm9vYmFyYmF6

    Meeting ID: 812 3456 7890
    Passcode: 123456

    Having trouble? Download the app at https://zoom.us/download or test your audio at
    https://zoom.us/test
    """

    func testTheJoinLinkWinsOverAnImageThatAppearsBeforeIt() {
        let found = MeetingLink.detect(location: nil, notes: zoomInvite, url: nil)
        XCTAssertEqual(found?.platform, .zoom)
        XCTAssertEqual(found?.url.absoluteString,
                       "https://us02web.zoom.us/j/81234567890?pwd=Zm9vYmFyYmF6")
    }

    func testAnImageOnTheMeetingDomainIsNeverAJoinLink() {
        let logo = URL(string: "https://us02web.zoom.us/static/94973/image/new/ZoomLogo.png")!
        XCTAssertEqual(MeetingLink.joinRank(logo), 0)
        XCTAssertTrue(MeetingLink.isAsset(logo))
        // Even alone in the notes, it must not produce a button.
        XCTAssertNil(MeetingLink.detect(location: nil, notes: logo.absoluteString, url: nil))
    }

    func testAssetsAreRecognisedByExtensionAndByPathSegment() {
        for raw in ["https://zoom.us/a/banner.jpg",
                    "https://zoom.us/static/x/y",
                    "https://zoom.us/assets/app.css",
                    "https://zoom.us/img/hero.webp",
                    "https://zoom.us/logo-large"] {
            XCTAssertTrue(MeetingLink.isAsset(URL(string: raw)!), raw)
        }
        XCTAssertFalse(MeetingLink.isAsset(URL(string: "https://us02web.zoom.us/j/81234567890")!))
    }

    /// "Download Zoom" is a real page, so it is not excluded outright — but it must never beat an
    /// actual meeting, and it should only ever surface if the invite has nothing better.
    func testUtilityPagesRankBelowARealJoinLink() {
        let join = URL(string: "https://us02web.zoom.us/j/81234567890")!
        let download = URL(string: "https://zoom.us/download")!
        XCTAssertGreaterThan(MeetingLink.joinRank(join), MeetingLink.joinRank(download))

        let onlyHelp = "Trouble? https://zoom.us/download or https://zoom.us/test"
        XCTAssertEqual(MeetingLink.detect(location: nil, notes: onlyHelp, url: nil)?.url, download,
                       "with nothing joinable, a real page still beats no button at all")
    }

    // MARK: - Join shapes per platform

    func testZoomJoinShapesAreRecognised() {
        for path in ["/j/81234567890", "/w/81234567890", "/s/81234567890", "/my/sam", "/wc/join/8123"] {
            let url = URL(string: "https://us02web.zoom.us\(path)")!
            XCTAssertEqual(MeetingLink.joinRank(url), 4, path)
        }
    }

    func testAGoogleMeetCodeIsRecognisedButItsHelpPagesAreNot() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertEqual(MeetingLink.joinRank(meet), 4)
        XCTAssertEqual(MeetingLink.detect(location: nil, notes: "Join: \(meet.absoluteString)", url: nil)?.platform, .meet)
    }

    func testTeamsMeetupJoinIsRecognised() {
        let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%7d")!
        XCTAssertEqual(MeetingLink.joinRank(teams), 4)
    }

    // MARK: - Host matching

    /// `classify` used to accept any host merely CONTAINING the brand, which made its exact and
    /// subdomain tests dead code and matched hosts that only embed the string.
    func testHostMatchingIsExactOrSubdomainNotSubstring() {
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://zoom.us/j/1")!), .zoom)
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://us02web.zoom.us/j/1")!), .zoom)
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://notzoom.usurper.example/j/1")!), .generic)
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://myzoom.uscompany.com/j/1")!), .generic)
    }

    // MARK: - Behaviour that must not regress

    func testABareDomainInTheLocationLosesToTheRealLinkInTheNotes() {
        let found = MeetingLink.detect(location: "zoom.us",
                                       notes: "Join https://us02web.zoom.us/j/81234567890", url: nil)
        XCTAssertEqual(found?.url.absoluteString, "https://us02web.zoom.us/j/81234567890")
    }

    func testAPlainURLInTheLocationIsStillAGenericVideoLink() {
        let found = MeetingLink.detect(location: "https://example.com/room/abc", notes: nil, url: nil)
        XCTAssertEqual(found?.platform, .generic)
        XCTAssertEqual(found?.url.absoluteString, "https://example.com/room/abc")
    }

    func testAnOrdinaryInPersonEventHasNoJoinLink() {
        XCTAssertNil(MeetingLink.detect(location: "Blue Bottle, 1 Market St", notes: "Coffee", url: nil))
    }

    func testTheEventURLFieldIsStillConsidered() {
        let found = MeetingLink.detect(location: "Online", notes: nil,
                                       url: URL(string: "https://us02web.zoom.us/j/999"))
        XCTAssertEqual(found?.platform, .zoom)
    }

    // MARK: Reading less text (a calendar window looks at every meeting on every read)

    func testAJoinLinkAlreadyFoundIsNotBeatenByTheNotes() {
        // Google's own Meet link, and a Zoom invite pasted into the description: the earlier,
        // equally good link wins, exactly as when the notes were always read.
        let found = MeetingLink.detect(location: nil, notes: zoomInvite,
                                       url: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(found?.platform, .meet)
        XCTAssertEqual(found?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testABetterLinkInTheNotesStillBeatsAWeakerOneFoundFirst() {
        let found = MeetingLink.detect(location: "zoom.us", notes: zoomInvite, url: nil)
        XCTAssertEqual(found?.url.absoluteString,
                       "https://us02web.zoom.us/j/81234567890?pwd=Zm9vYmFyYmF6")
    }

    func testOnlyTextThatSpellsOutAPlatformCanHoldAJoinLink() {
        XCTAssertTrue(MeetingPlatform.mayNameAPlatform("Join at US02WEB.ZOOM.US/j/123"))
        XCTAssertTrue(MeetingPlatform.mayNameAPlatform("https://meet.jit.si/standup"))
        XCTAssertTrue(MeetingPlatform.mayNameAPlatform("https://video.our-jitsi.example.org/room"))
        XCTAssertFalse(MeetingPlatform.mayNameAPlatform("Menu: https://example.com/lunch, call 555-0100"))
        XCTAssertNil(MeetingLink.detect(location: nil,
                                        notes: "Agenda https://docs.example.com/d/1 and https://example.org",
                                        url: nil))
    }

    func testEveryBrandedLinkIsSpelledOutInItsOwnText() {
        for link in ["https://zoom.us/j/1", "https://x.zoomgov.com/j/1", "https://meet.google.com/abc-defg-hij",
                     "https://teams.microsoft.com/l/meetup-join/1", "https://teams.live.com/meet/1",
                     "https://acme.webex.com/meet/b", "https://cal.com/b/1", "https://whereby.com/room",
                     "https://global.gotomeeting.com/join/1", "https://gotomeet.me/b", "https://app.goto.com/1",
                     "https://bluejeans.com/1", "https://app.chime.aws/meetings/1", "https://ch022.on.aws/1",
                     "https://v.ringcentral.com/join/1", "https://rcvideo.com/1", "https://meet.jit.si/r",
                     "https://join.skype.com/1", "https://discord.gg/1", "https://discord.com/1",
                     "https://acme.slack.com/huddle/1", "https://around.co/r/1", "https://8x8.vc/1",
                     "https://8x8.com/1", "https://hangouts.google.com/call/1",
                     "https://facetime.apple.com/join#v=1", "https://join.gong.io/1"] {
            let url = URL(string: link)!
            XCTAssertNotEqual(MeetingPlatform.classify(url), .generic, link)
            XCTAssertTrue(MeetingPlatform.mayNameAPlatform("Join: \(link)"), link)
        }
    }

    func testTheHostTableKeepsItsOrder() {
        // Jitsi's anywhere-match came before Slack's domain; it still does.
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://jitsi.slack.com/x")!), .jitsi)
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://hangouts.google.com/call/1")!), .hangouts)
        XCTAssertEqual(MeetingPlatform.classify(URL(string: "https://example.com/zoom.us")!), .generic)
    }

    func testARememberedAnswerFollowsTheEventsText() {
        let first = MeetingLink.detect(location: nil, notes: zoomInvite, url: nil)
        let again = MeetingLink.detect(location: nil, notes: zoomInvite, url: nil)
        XCTAssertEqual(first?.url, again?.url)
        let edited = MeetingLink.detect(location: nil, notes: "Moved to https://meet.google.com/xyz-abcd-efg",
                                        url: nil)
        XCTAssertEqual(edited?.platform, .meet)
        XCTAssertNil(MeetingLink.detect(location: nil, notes: "Moved to the office", url: nil))
    }
}
