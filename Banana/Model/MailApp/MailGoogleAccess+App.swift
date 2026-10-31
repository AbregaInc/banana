#if !BANANA_PUBLIC
import Foundation

extension MailGoogleAccess {
    @MainActor static func configured() async throws -> MailGoogleAccess {
        try await load(storage: MailCredentialStore(service: AppVariant.current.mailKeychainService),
            accountIDs: { GoogleCalendarService.shared.accounts.map(\.id) },
            clientID: {
                let value = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            },
            consent: { try await GoogleCalendarService.shared.googleConsent(hint: $0, scopes: $1) })
    }
}

#endif
