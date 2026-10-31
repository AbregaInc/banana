import XCTest

/// What the app sends the Banana service and reads back (`BananaService`, docs/design/ACCOUNTS.md).
final class BananaServiceTests: XCTestCase {
    private let device = BananaService.Device(id: "6F1C2E0A-0000-4000-8000-000000000001", platform: "iphone",
                                              push: nil, pushEnv: "development", bundle: "com.boris.banana")

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testSigningInSendsTheCodeAndThisDeviceWithoutASessionUntilThereIsOne() throws {
        let request = BananaService.request(.signIn(code: "4/0Abc", device: device), host: "service.example", session: nil)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://service.example/v1/google")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        XCTAssertEqual(body["code"] as? String, "4/0Abc")
        let sent = try XCTUnwrap(body["device"] as? [String: Any])
        XCTAssertEqual(sent["id"] as? String, device.id)
        XCTAssertEqual(sent["platform"] as? String, "iphone")
        XCTAssertTrue(sent["push"] is NSNull, "no push token yet is said as null")
        XCTAssertEqual(sent["pushEnv"] as? String, "development")
    }

    func testSignedInCallsCarryTheSession() throws {
        let request = BananaService.request(.account, host: "service.example", session: "abc")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertNil(request.httpBody)
    }

    func testADeviceIsPutAtItsOwnAddress() throws {
        var withPush = device
        withPush.push = "a1b2"
        let request = BananaService.request(.device(withPush), host: "service.example", session: "abc")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/devices/\(device.id)")
        let body = try json(request)
        XCTAssertNil(body["id"], "the id is the address, not the body")
        XCTAssertEqual(body["push"] as? String, "a1b2")
    }

    func testGoogleAccountsAreNamedByLowercasedEmail() throws {
        let open = BananaService.request(.openChannel(email: "Noor@Example.com", calendarID: "a"),
                                         host: "service.example", session: "abc")
        XCTAssertEqual(open.httpMethod, "POST")
        XCTAssertEqual(open.url?.path, "/v1/google/channels")
        XCTAssertEqual(try json(open)["email"] as? String, "noor@example.com")
        XCTAssertEqual(try json(open)["calendarId"] as? String, "a")
        let unlink = BananaService.request(.unlink(email: "Noor@Example.com"), host: "service.example", session: "abc")
        XCTAssertEqual(unlink.httpMethod, "DELETE")
        XCTAssertEqual(try json(unlink)["email"] as? String, "noor@example.com")
    }

    func testSigningInByIdentitySendsGoogleIdentityTokenAndTheDevice() throws {
        // No sign-in sheet: the token comes from the refresh token the app already holds.
        let request = BananaService.request(.identity(idToken: "eyJ.x.y", device: device), host: "service.example", session: nil)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/google/identity")
        let body = try json(request)
        XCTAssertEqual(body["idToken"] as? String, "eyJ.x.y")
        XCTAssertEqual((body["device"] as? [String: Any])?["id"] as? String, device.id)
    }

    func testAWatchIsConfirmedWithGooglesAnswerInMilliseconds() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let request = BananaService.request(.confirmChannel(id: "c1", resourceID: "r1", expiration: when),
                                            host: "service.example", session: "abc")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/google/channels/c1")
        XCTAssertEqual(try json(request)["resourceId"] as? String, "r1")
        XCTAssertEqual(try json(request)["expiration"] as? Int, 1_800_000_000_000)
        XCTAssertEqual(BananaService.request(.closeChannel(id: "c1"), host: "service.example", session: "abc").httpMethod, "DELETE")
    }

    func testEveryWantedCalendarGetsOneWatchThatOutlastsTheDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = { (days: Double) in (now.timeIntervalSince1970 + days * 86_400) * 1000 }
        func ch(_ id: String, _ email: String, _ cal: String, _ days: Double?, status: String = "live") -> BananaService.Channel {
            .init(id: id, email: email, calendarId: cal, resourceId: status == "live" ? "r-\(id)" : nil, status: status,
                  expiresAt: days.map(ms))
        }
        let channels = [
            ch("fresh", "a@x.com", "primary", 5),
            ch("spare", "a@x.com", "primary", 3),          // a second watch on the same calendar
            ch("ending", "a@x.com", "family", 0.5),         // ends within the day: renew
            ch("gone", "a@x.com", "old", 5),                 // no longer read
            ch("mid", "b@x.com", "work", nil, status: "pending"),  // another device opening it
        ]
        let plan = BananaService.watchPlan(wanted: ["a@x.com": ["family", "primary"], "b@x.com": ["work"]],
                                           channels: channels, now: now)
        XCTAssertEqual(plan.open.map { "\($0.email)/\($0.calendarID)" }, ["a@x.com/family", "b@x.com/work"])
        XCTAssertEqual(Set(plan.close.map(\.id)), ["spare", "gone"])
        XCTAssertEqual(plan.replaced["a@x.com\nfamily"]?.map(\.id), ["ending"], "closed only once its new watch is open")
    }

    func testOnlyGoogleAccountsNotYetInTheBananaAccountAreLinked() {
        // Every pass used to send all four accounts again (four token mints, four calls, four
        // audit rows), because the account wasn't read first (18 Oct 2026).
        XCTAssertEqual(BananaService.accountsToLink(connected: ["a@x.com", "B@x.com", "c@x.com"],
                                                    linked: ["b@x.com"], signedIn: true), ["a@x.com", "c@x.com"])
        XCTAssertEqual(BananaService.accountsToLink(connected: ["a@x.com"], linked: ["a@x.com"], signedIn: true), [])
        XCTAssertEqual(BananaService.accountsToLink(connected: ["a@x.com"], linked: ["a@x.com"], signedIn: false), ["a@x.com"],
                       "signed out, the first account signs in whatever the stale description says")
    }

    func testAccountsTheServiceHasNoAccessForAreToSignInAgain() throws {
        let account = BananaService.Account(id: "acc", google: [
            .init(email: "A@x.com", status: "ok", watching: 3, access: false),   // joined by identity token
            .init(email: "b@x.com", status: "ok", watching: 1, access: true),    // signed in with a code
            .init(email: "c@x.com", status: "refused", watching: 0, access: false),
            .init(email: "gone@x.com", status: "ok", watching: 0, access: false), // no longer connected here
        ], devices: 1)
        XCTAssertEqual(BananaService.accountsToSignInAgain(connected: ["a@x.com", "b@x.com", "c@x.com"], account: account),
                       ["a@x.com", "c@x.com"])
        XCTAssertEqual(BananaService.accountsToSignInAgain(connected: ["a@x.com"], account: nil), [])
        // A service from before the flag says nothing: nobody is asked.
        let old = try JSONDecoder().decode(BananaService.Account.self,
                                           from: Data(#"{"id":"acc","google":[{"email":"a@x.com","status":"ok","watching":2}],"devices":1}"#.utf8))
        XCTAssertNil(old.google[0].access)
        XCTAssertEqual(BananaService.accountsToSignInAgain(connected: ["a@x.com"], account: old), [])
    }

    func testChangesAreInstantOnlyWithAPushTokenRegisteredAndALiveWatch() {
        let watching = BananaService.Account(id: "acc", google: [.init(email: "a@x.com", status: "ok", watching: 3)], devices: 2)
        let none = BananaService.Account(id: "acc", google: [.init(email: "a@x.com", status: "ok", watching: 0)], devices: 2)
        let refused = BananaService.Account(id: "acc", google: [.init(email: "a@x.com", status: "refused", watching: 3)], devices: 2)
        XCTAssertTrue(BananaService.updatesAreInstant(pushRegistered: true, account: watching))
        XCTAssertFalse(BananaService.updatesAreInstant(pushRegistered: false, account: watching), "no push token with the service")
        XCTAssertFalse(BananaService.updatesAreInstant(pushRegistered: true, account: none), "nothing watched at Google")
        XCTAssertFalse(BananaService.updatesAreInstant(pushRegistered: true, account: refused))
        XCTAssertFalse(BananaService.updatesAreInstant(pushRegistered: true, account: nil))
    }

    func testEventAlertCallsAndTheClearPush() throws {
        let held = BananaService.request(.heldAlerts(device: "dev-1", report: .init(ids: ["c|e|5", "c|e|0"], calendars: ["c"], quiet: [])),
                                         host: "h", session: "s")
        XCTAssertEqual([held.httpMethod, held.url?.path], ["PUT", "/v1/alerts/held"])
        XCTAssertEqual(try json(held)["ids"] as? [String], ["c|e|0", "c|e|5"])
        let clear = BananaService.request(.clearAlert(id: "c|e|5", device: "dev-1"), host: "h", session: "s")
        XCTAssertEqual([clear.httpMethod, clear.url?.path], ["POST", "/v1/alerts/clear"])
        XCTAssertEqual(try json(clear)["id"] as? String, "c|e|5")
        let settings = BananaService.request(.alertSettings(leads: [5, 0], timeZone: "America/New_York"), host: "h", session: "s")
        XCTAssertEqual(settings.url?.path, "/v1/account/alerts")
        XCTAssertEqual(try json(settings)["leads"] as? [Int], [5, 0])
        XCTAssertEqual(BananaService.alertClearID(["aps": ["content-available": 1], "b": ["k": "alert-clear", "id": "c|e|5"]]), "c|e|5")
        XCTAssertNil(BananaService.alertClearID(["b": ["k": "calendar"]]))
        XCTAssertFalse(BananaService.isCalendarPush(["b": ["k": "alert-clear", "id": "x"]]))
    }

    func testALocalAlertsIdIsTheOneTheServiceUses() {
        // The device plans `<infoID>#<lead>`; the service names `calendarId|eventId|lead`.
        let infoID = GoogleCalendarIDs.eventInfoID(calendarID: "ann@example.com", eventID: "abc123")
        XCTAssertEqual(BananaService.alertID(planItemID: "\(infoID)#5"), "ann@example.com|abc123|5")
        XCTAssertEqual(BananaService.alertID(planItemID: "\(infoID)#now"), "ann@example.com|abc123|now")
        XCTAssertEqual(BananaService.alertRoute(of: "ann@example.com|abc123|5")?.eventID, "abc123")
        XCTAssertNil(BananaService.alertRoute(of: "ann@example.com|abc123"))
        // Not Google's: the plan's own id stays.
        XCTAssertEqual(BananaService.alertID(planItemID: "ek:1#5"), "ek:1#5")
    }

    func testDeletingSendsAFreshSignInsCode() throws {
        // A session alone never deletes the account (docs/design/ACCOUNTS.md, 18 Oct 2026).
        let request = BananaService.request(.deleteAccount(code: "4/0Fresh"), host: "service.example", session: "abc")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/account")
        XCTAssertEqual(try json(request)["code"] as? String, "4/0Fresh")
    }

    func testUsageGoesAsItIs() {
        let batch = Data(#"{"platform":"mac"}"#.utf8)
        let request = BananaService.request(.usage(batch), host: "service.example", session: nil)
        XCTAssertEqual(request.url?.path, "/v1/usage")
        XCTAssertEqual(request.httpBody, batch)
    }

    func testTheAccountAndAnswersRead() throws {
        let answer = try JSONDecoder().decode(BananaService.SignInAnswer.self, from: Data(#"""
        {"session":"s1","account":{"id":"acc","google":[{"email":"a@example.com","status":"ok","watching":3}],"devices":2}}
        """#.utf8))
        XCTAssertEqual(answer.session, "s1")
        XCTAssertEqual(answer.account.google, [.init(email: "a@example.com", status: "ok", watching: 3)])
        XCTAssertEqual(BananaService.failure(in: Data(#"{"error":"other_account"}"#.utf8)), "other_account")
        XCTAssertNil(BananaService.failure(in: Data()))
    }

    func testOnlyTheServicesCalendarPushIsOne() {
        XCTAssertTrue(BananaService.isCalendarPush(["aps": ["content-available": 1], "b": ["k": "calendar"]]))
        XCTAssertFalse(BananaService.isCalendarPush(["aps": ["content-available": 1], "ck": ["sid": "meals-zone-changes"]]))
        XCTAssertFalse(BananaService.isCalendarPush(["b": ["k": "mail"]]))
    }

    func testAPushTokenIsSentAsHex() {
        XCTAssertEqual(BananaService.hex(Data([0x00, 0xab, 0x10, 0xff])), "00ab10ff")
    }

    func testCalendarsToWatchArePerAccountLessTheOnesThatDontCount() {
        let lists = BananaService.watchLists(
            calendars: [("A@example.com", "work", false), ("a@example.com", "home", false), ("b@example.com", "holidays", false),
                        ("a@example.com", "work", false)],
            excluded: ["holidays"])
        XCTAssertEqual(lists, ["a@example.com": ["home", "work"]])
    }

    /// 19 Oct 2026: the service rang for calendars the devices leave out — a hidden one, and ones
    /// set not to count, which Settings keeps by info id and the list compared by raw id.
    func testHiddenCalendarsAndOnesSetNotToCountByInfoIDAreNeitherWatchedNorRungFor() {
        let lists = BananaService.watchLists(
            calendars: [("a@example.com", "a@example.com", false), ("a@example.com", "launches@group", true),
                        ("a@example.com", "partner@example.com", false)],
            excluded: [GoogleCalendarIDs.calendarInfoID("partner@example.com")])
        XCTAssertEqual(lists, ["a@example.com": ["a@example.com"]])
    }

    func testTheHeldReportSaysWhatTheDeviceRingsForAndSkips() throws {
        let report = BananaService.HeldReport(ids: ["c|e|5", "c|e|5", "c|e|0"], calendars: ["c", "b"], quiet: ["c|skipped"])
        let request = BananaService.request(.heldAlerts(device: "d1", report: report), host: "h", session: "s")
        let body = try json(request)
        XCTAssertEqual(body["ids"] as? [String], ["c|e|0", "c|e|5"])
        XCTAssertEqual(body["calendars"] as? [String], ["b", "c"])
        XCTAssertEqual(body["quiet"] as? [String], ["c|skipped"])
        // Without a whole calendar list it says no calendars, and the service rings it for nothing.
        let partial = BananaService.request(.heldAlerts(device: "d1", report: .init(ids: [], calendars: nil, quiet: [])), host: "h", session: "s")
        XCTAssertNil(try json(partial)["calendars"])
        XCTAssertEqual(BananaService.alertEvent(infoID: GoogleCalendarIDs.eventInfoID(calendarID: "c@x", eventID: "e_1")), "c@x|e_1")
        XCTAssertNil(BananaService.alertEvent(infoID: "reminder:123"))
    }

    /// Build 59 doubled the ending on a whole client id, so Google gave no code for the service.
    func testTheServerClientIdIsWholeWhicheverFormTheSettingHolds() {
        XCTAssertEqual(BananaService.fullClientID("123-abc"), "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(BananaService.fullClientID("123-abc.apps.googleusercontent.com"), "123-abc.apps.googleusercontent.com")
    }

    func testNothingIsConfiguredFromAnEmptyOrUnfilledSetting() {
        let bundle = Bundle(for: Self.self)
        XCTAssertNil(BananaService.configured("NoSuchKey", in: bundle))
    }
}
