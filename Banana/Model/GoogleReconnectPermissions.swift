import Foundation

/// The only scopes Banana asks Google for: exactly the set submitted for OAuth verification and
/// listed on the Cloud Console's Data Access page (docs/release/google-oauth-verification-reply.md).
/// Google refuses verification when a request names a scope the Console doesn't list, so every
/// sign-in is cut to this set before it reaches Google. Google Sign-In adds `openid`, `email` and
/// `profile` itself. A new scope goes here, on the Console and in the verification reply together.
enum GoogleScopes {
    static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
    static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    #if BANANA_PUBLIC
    static let submitted: Set<String> = [calendarEvents, calendarList]
    #else
    static let submitted: Set<String> = Set([calendarEvents, calendarList, MailScopes.gmailModify] + MailScopes.senderPhotos)
    #endif

    /// `requested`, without anything outside `submitted`, sorted and without repeats.
    static func allowed(_ requested: [String]) -> [String] {
        Set(requested).intersection(submitted).sorted()
    }
}

#if !BANANA_PUBLIC
/// Reconnect restores Mail for an account that had it, and never enrolls a Calendar-only account.
/// It asks for Mail's current scopes, not the ones last granted: an older grant can hold
/// `gmail.readonly` or full Gmail access, which are not submitted scopes, so a read-only grant
/// comes back as `gmail.modify`.
enum GoogleReconnectPermissions {
    static func scopes(calendar: [String], mail: [String], readable: Bool, enabled: Bool) -> [String] {
        let gmail = ["https://www.googleapis.com/auth/gmail.readonly", MailScopes.gmailModify, "https://mail.google.com/"]
        guard enabled, readable || mail.contains(where: gmail.contains) else { return Array(Set(calendar)).sorted() }
        return Array(Set(calendar + [MailScopes.gmailModify] + MailScopes.senderPhotos)).sorted()
    }
}
#endif
