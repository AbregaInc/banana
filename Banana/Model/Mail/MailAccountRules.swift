#if !BANANA_PUBLIC
import Foundation

/// Whether one account's mail can be used on this device (MAIL-ENGINE 3.4).
///
/// Mail is either connected or not: the account is connected to Banana and its Google grant
/// includes Gmail, or it is not. There is no per-account switch and no read-only mode.
/// The decision is made once, here, from the facts alone: it reads no setting, no keychain and
/// no clock, which is why every row of it is tested directly (`MailAccountRulesTests`).
enum MailAccountRules {

    /// The state of one account's mail, by the first of these that holds:
    ///
    /// 1. **`notConnected`** — the grant does not include Gmail (never given, or Google refused
    ///    it), Gmail answered 403 for a missing scope since the grant, or the token's own scope
    ///    list is *known* and lacks Gmail. A scope list that is unknown (nil) proves nothing
    ///    and does not count; see `MailScopes.parse`. Connecting the Google account again is
    ///    the way back.
    /// 2. **`waitingForFirstOpen`** — connected, but this device has not opened Mail yet, so
    ///    nothing has been fetched and nothing should be (invariant 16).
    /// 3. **`connected`**.
    ///
    /// - Parameters:
    ///   - activatedOnThisDevice: whether this device has ever opened Mail.
    ///   - grant: whether the account's Google grant includes Gmail.
    ///   - tokenScopes: the scopes Google last said an access token carries; nil if it did not
    ///     say.
    ///   - serverRefusedScope: Gmail has answered 403 for a missing scope since the grant.
    static func state(activatedOnThisDevice: Bool,
                      grant: MailGrant,
                      tokenScopes: Set<String>?,
                      serverRefusedScope: Bool) -> MailAccountState {
        guard grant == .granted, !serverRefusedScope else { return .notConnected }
        if let tokenScopes, !tokenScopes.contains(MailScopes.gmailModify) { return .notConnected }
        return activatedOnThisDevice ? .connected : .waitingForFirstOpen
    }
}

#endif
