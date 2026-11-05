#if !BANANA_PUBLIC
import Foundation

/// The existing Banana identity selects Mail access on every device. Provider grants stay in Cloud.
@MainActor final class MailCloudAccess: MailAccountAccess {
    private var consenting = false
    var connectedAccountIDs: [String] { BananaAccount.shared.account?.google.map { $0.email.lowercased() } ?? [] }
    func mailGrant(accountID: String) -> MailGrant {
        guard FeatureAccessStore.shared.allows("email"), let link = linked(accountID) else { return .none }
        return link.capabilities?.mailRead == true ? .granted : .none
    }
    func mailAccessToken(accountID: String) async throws -> MailAccessToken {
        guard let link = linked(accountID) else { throw MailAccessError.unknownAccount }
        guard let context = FeatureAccessStore.shared.mailContext else { throw MailAccessError.notGranted }
        guard link.capabilities?.mailRead == true else { throw MailAccessError.notGranted }
        let scope = link.capabilities?.mailModify == true ? MailScopes.gmailModify : "https://www.googleapis.com/auth/gmail.readonly"
        return MailAccessToken(value: CloudMailReference(email: accountID, context: context).value, scopes: [scope])
    }
    func dropMailAccessToken(accountID: String) { Task { _ = await BananaAccount.shared.refresh() } }
    func cancelMailTokenRequests() { /* No device-side Google token mint exists. */ }
    func requestMailAccess(accountID: String) async -> MailAccessOutcome {
        guard linked(accountID) != nil else { return .failed(.unknownAccount) }
        guard let context = FeatureAccessStore.shared.mailContext else { return .failed(.notGranted) }
        guard !consenting else { return .cancelled }
        consenting = true; defer { consenting = false }
        do {
            let result = try await GoogleCalendarService.shared.googleConsent(hint: accountID, scopes: [MailScopes.gmailModify])
            guard result.email.lowercased() == accountID.lowercased() else { return .differentAccount }
            guard result.grantedScopes.contains(MailScopes.gmailModify) else { return .declined }
            guard let code = result.serverAuthCode else { return .failed(.notConfigured) }
            let status = try await BananaAccount.shared.mailConsent(email: accountID, code: code, context: context)
            if status == 409 { return .differentAccount }
            guard status == 200 else { return .failed(.transport) }
            return mailGrant(accountID: accountID) == .granted ? .granted : .declined
        } catch is CancellationError { return .cancelled }
        catch GoogleConsentError.cancelled { return .cancelled }
        catch GoogleConsentError.noWindow { return .noWindow }
        catch { return .failed(.transport) }
    }
    func forgetMailAccess(accountID: String) async throws {
        try await BananaAccount.shared.disconnectMail(email: accountID)
    }
    private func linked(_ email: String) -> BananaService.Account.Google? {
        BananaAccount.shared.account?.google.first { $0.email.lowercased() == email.lowercased() }
    }
}
#endif
