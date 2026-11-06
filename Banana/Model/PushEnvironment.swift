import Foundation
#if os(macOS)
import Security
#endif

/// A Developer ID Mac app has a provisioning profile just like a local build,
/// but its token belongs to production APNs. Signing decides the push route.
enum PushEnvironment {
    private static let signedEntitlement: String? = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        #else
        return nil
        #endif
    }()

    static func current(isDevelopmentInstall: Bool) -> String {
        resolve(signedEntitlement: signedEntitlement, isDevelopmentInstall: isDevelopmentInstall)
    }

    static func resolve(signedEntitlement: String?, isDevelopmentInstall: Bool) -> String {
        if let signedEntitlement, ["development", "production"].contains(signedEntitlement) {
            return signedEntitlement
        }
        // iOS has no public SecTask API. Preserve its installed-profile/receipt
        // classification; unsigned Mac test hosts use the same fallback.
        return isDevelopmentInstall ? "development" : "production"
    }
}
