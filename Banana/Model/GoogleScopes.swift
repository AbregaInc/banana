import Foundation

/// Every Google consent asks for all of these, whichever surface starts it: first run, adding or
/// reconnecting an account, turning on Mail, sender photos. One grant then serves every surface of
/// the app, and whatever is granted updates them all (`GoogleCalendarService.grantChanged`, and
/// the service stores the Calendar and Mail grants from any consent that carries them).
///
/// It is exactly the set submitted for Google's OAuth verification and listed on the Cloud
/// Console's Data Access page (docs/release/google-oauth-verification-reply.md): Google refuses
/// verification when a request names a scope the Console doesn't list. Google Sign-In adds
/// `openid`, `email` and `profile` itself. A new scope goes here, on the Console and in the
/// verification reply together.
///
/// A build without Email (TestFlight, the App Store) carries no Gmail or contacts scope; its
/// release check refuses one.
enum GoogleScopes {
    static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
    static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    #if BANANA_PUBLIC
    static let all: [String] = [calendarEvents, calendarList].sorted()
    #else
    static let all: [String] = ([calendarEvents, calendarList, MailScopes.gmailModify] + MailScopes.senderPhotos).sorted()
    #endif
}
