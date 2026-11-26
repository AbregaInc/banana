#if !BANANA_PUBLIC
import Foundation

extension MailGoogleAccess {
    @MainActor static func configured() async throws -> MailGoogleAccess {
        try await load(storage: MailCredentialStore(service: AppVariant.current.mailKeychainService),
            accountIDs: { GoogleCalendarService.shared.accounts.map(\.id) },
            clientID: {
                guard FeatureAccessStore.shared.allows("email") else { return nil }
                let value = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            },
            consent: { account, _ in
                guard FeatureAccessStore.shared.allows("email") else { throw GoogleConsentError.notConfigured }
                return try await GoogleCalendarService.shared.googleConsent(hint: account)
            })
    }
}

#endif
