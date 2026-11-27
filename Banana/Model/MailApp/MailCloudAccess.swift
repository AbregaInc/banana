#if !BANANA_PUBLIC
import Foundation

/// The existing Banana identity selects Mail access on every device. Provider grants stay in Cloud.
@MainActor final class MailCloudAccess: MailAccountAccess {
    private var consenting = false
    var connectedAccountIDs: [String] {
        BananaAccount.shared.account?.google.map { $0.email.lowercased() }
            ?? FeatureAccessStore.shared.cachedMailAccounts ?? []
    }
    func mailGrant(accountID: String) -> MailGrant {
        guard FeatureAccessStore.shared.allows("email"), let link = linked(accountID) else { return .none }
        return link.capabilities?.mailModify == true ? .granted : .none
    }
    func mailAccessToken(accountID: String) async throws -> MailAccessToken {
        // At launch Mail opens from the cached account list before the service has described the
        // account (it is not kept between launches). Not described yet is not unknown: wait for
        // the one shared refresh instead of failing the first reads.
        if BananaAccount.shared.account == nil, BananaAccount.shared.isSignedIn {
            await MailApplication.shared.refreshAccount()
        }
        guard let link = linked(accountID) else { throw MailAccessError.unknownAccount }
        guard let context = FeatureAccessStore.shared.mailContext else { throw MailAccessError.notGranted }
        guard link.capabilities?.mailModify == true else { throw MailAccessError.notGranted }
        return MailAccessToken(value: CloudMailReference(email: accountID, context: context).value, scopes: [MailScopes.gmailModify])
    }
    func dropMailAccessToken(accountID: String) { Task { _ = await BananaAccount.shared.refresh() } }
    func cancelMailTokenRequests() { /* No device-side Google token mint exists. */ }
    /// Connecting Mail is connecting the Google account again: the normal reconnect asks for
    /// every scope and hands the code to the service.
    func requestMailAccess(accountID: String) async -> MailAccessOutcome {
        guard linked(accountID) != nil else { return .failed(.unknownAccount) }
        guard !consenting else { return .cancelled }
        consenting = true; defer { consenting = false }
        switch await GoogleCalendarService.shared.reconnect(email: accountID) {
        case .cancelled: return .cancelled
        case .differentAccount: return .differentAccount
        case .failed: return .failed(.transport)
        case .connected(let granted):
            guard granted.contains(MailScopes.gmailModify) else { return .declined }
            if mailGrant(accountID: accountID) != .granted { _ = await BananaAccount.shared.refresh() }
            return mailGrant(accountID: accountID) == .granted ? .granted : .failed(.transport)
        }
    }
    private func linked(_ email: String) -> BananaService.Account.Google? {
        BananaAccount.shared.account?.google.first { $0.email.lowercased() == email.lowercased() }
    }
}
#endif
