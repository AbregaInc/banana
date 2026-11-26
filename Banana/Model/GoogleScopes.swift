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

extension GoogleScopes {
    /// What Google's screen asks for, grouped the way a person thinks of it. A consent that comes
    /// back without one of these is explained and asked again (`GoogleConsentRetry`).
    enum Permission: String, CaseIterable, Identifiable, Sendable {
        case calendar, gmail, contacts
        var id: String { rawValue }

        var title: String {
            switch self {
            case .calendar: "Calendar"
            case .gmail: "Gmail"
            case .contacts: "Contacts"
            }
        }

        /// Why Banana needs it, in a few words.
        var reason: String {
            switch self {
            case .calendar: "Shows and plans your day"
            case .gmail: "Reads, sorts and sends your mail"
            case .contacts: "Shows the photos you gave people"
            }
        }

        var symbol: String {
            switch self {
            case .calendar: "calendar"
            case .gmail: "envelope"
            case .contacts: "person.crop.circle"
            }
        }

        var scopes: [String] {
            switch self {
            case .calendar: [GoogleScopes.calendarEvents, GoogleScopes.calendarList]
            #if BANANA_PUBLIC
            case .gmail, .contacts: []
            #else
            case .gmail: [MailScopes.gmailModify]
            case .contacts: MailScopes.senderPhotos
            #endif
            }
        }
    }

    /// The permissions this build asks for, in the order Google's screen lists them.
    static var permissions: [Permission] { Permission.allCases.filter { !$0.scopes.isEmpty } }

    /// The permissions a grant lacks: any scope of one missing counts it as missing.
    static func missing(granted: Set<String>) -> [Permission] {
        permissions.filter { !Set($0.scopes).isSubset(of: granted) }
    }
}
