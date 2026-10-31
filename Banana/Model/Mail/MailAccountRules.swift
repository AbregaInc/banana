#if !BANANA_PUBLIC
import Foundation

/// Whether one account's mail can be used on this device, and if not, which of two things to
/// tell him (MAIL-ENGINE 3.4).
///
/// The screens need one word per account — off, waiting, needs access, connected — and four
/// separate facts decide it, which come from four different places: a synced setting, a
/// device-local marker, the keychain, and what Google has just said. Left to each screen, two
/// of them would one day disagree about the same account, and a person would be shown "Mail is
/// connected" over a mailbox that has been returning 403 for a week. So the decision is made
/// once, here, from the facts alone: it reads no setting, no keychain and no clock, which is
/// why every row of it is tested directly (`MailAccountRulesTests`).
///
/// The two answers it speaks in, `MailAccountState` and `MailAccessGap`, are the contract's
/// because the screens name them; this file is the rule only.
///
/// **An account's calendar and its mail are judged apart.** The calendar can say "Sign in
/// again" while mail works, and the reverse, because mail holds a credential of its own (3.2).
/// Nothing here looks at the calendar, and no screen should infer one answer from the other.
enum MailAccountRules {

    /// The state of one account's mail, by the first of these that holds:
    ///
    /// 1. **`off`** — Mail is not turned on for the account. Whatever else is true of the
    ///    credential is not his concern while it is off, so nothing below can show through.
    /// 2. **`needsAccess(.notAllowedHere)`** — this device was never given Gmail for it. A
    ///    person who declined, or who has simply not been asked here yet, is not someone Google
    ///    refused; the screen offers to ask.
    /// 3. **`needsAccess(.withdrawn)`** — it was given and has since been taken back: Google
    ///    refused the stored credential, or Gmail answered 403 for a missing scope since the
    ///    grant, or the token's own scope list is *known* and lacks Gmail. A scope list that is
    ///    unknown (nil) proves nothing and does not count; see `MailScopes.parse`.
    /// 4. **`waitingForFirstOpen`** — everything is in order but this device has not opened
    ///    Mail yet, so nothing has been fetched and nothing should be (invariant 16).
    /// 5. **`connected`**.
    ///
    /// - Parameters:
    ///   - wantsMail: the synced choice, default off (D6).
    ///   - activatedOnThisDevice: whether this device has ever opened Mail.
    ///   - grant: what this device's keychain holds for the account's mail.
    ///   - tokenScopes: the scopes Google last said an access token carries; nil if it did not
    ///     say.
    ///   - serverRefusedScope: Gmail has answered 403 for a missing scope since the grant.
    static func state(wantsMail: Bool,
                      activatedOnThisDevice: Bool,
                      grant: MailGrant,
                      tokenScopes: Set<String>?,
                      serverRefusedScope: Bool) -> MailAccountState {
        guard wantsMail else { return .off }

        switch grant {
        case .none:
            return .needsAccess(.notAllowedHere)
        case .rejected:
            return .needsAccess(.withdrawn)
        case .granted:
            break
        }

        if serverRefusedScope { return .needsAccess(.withdrawn) }
        if let tokenScopes, !tokenScopes.contains(MailScopes.gmailModify) {
            return .needsAccess(.withdrawn)
        }

        return activatedOnThisDevice ? .connected : .waitingForFirstOpen
    }
}

#endif
