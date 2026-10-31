import Combine
import Foundation

/// The two questions the data platform asks a person (docs/design/DATA-PLATFORM.md §2, §7), and
/// what follows from the answers. Only with the data platform on (`SpaceSyncFlag`); the views are `SpaceSyncQuestionsView`.
///
/// - **The Health consent** (GDPR Art. 9). Asked once per account, on whichever device is first
///   about to send health or food data: after the update (the health tier waits on this device,
///   `MoveOver` `held`, with something to send), or when Health or Nutrition is first used. A yes
///   on any device is every device's (the engine learns it from the service). Without one the
///   question isn't asked again on its own; using Health or Nutrition on another device offers it
///   once more there. Settings › Banana account has the one switch to give or withdraw it.
/// - **Another account.** A different Google account signed in on a device whose mirror is
///   another's: once, whether to clear this device's data first. Yes clears what the adapters
///   hold and syncs for the new account; no syncs nothing for it.
@MainActor
final class SpaceSyncQuestions: ObservableObject {
    static let shared = SpaceSyncQuestions()

    /// The Health consent's words, by version: the service logs which words were agreed to.
    static let consentVersion = "health-2026-10-19"

    /// The consent screen is up.
    @Published var askingConsent = false
    /// The consent as this device knows it: given here, or learned from the service.
    @Published private(set) var consentGiven = false { didSet { if consentGiven != oldValue { consentChanged(consentGiven) } } }
    /// Hears the consent as this device knows it (an iPad or a Mac shows no Health without it).
    var consentChanged: (Bool) -> Void = { _ in }
    /// The engine runs for the signed-in account: the consent's switch shows.
    @Published private(set) var engineRunning = false
    /// The person said not to sync the account now signed in here (`Don't sync`): Settings offers
    /// to after all.
    @Published private(set) var declinedChange: (from: String, to: String)?
    /// A consent change is on its way to the service.
    @Published private(set) var sending = false
    /// The other-account question is up.
    @Published var askingAccountChange = false

    private let defaults: UserDefaults
    private var account: String?
    /// Whether this device holds health or food data to send (`SyncAdapters.healthAndFood`).
    var hasHealthData: () -> Bool = { false }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - The Health consent

    /// The engine for `account` is up and its stores have joined: hear the consent as it changes.
    func engineStarted(account: String, consent: Bool) {
        self.account = account
        engineRunning = true
        declinedChange = nil
        consentGiven = consent
        consentChanged(consent)
        MoveOver.onHealthConsentChanged = { [weak self] granted in
            Task { @MainActor in
                self?.consentGiven = granted
                // Another device's yes: nothing left to ask here.
                if granted { self?.askingConsent = false }
            }
        }
    }

    func engineStopped() {
        account = nil
        engineRunning = false
        askingConsent = false
    }

    private func askedKey(_ account: String) -> String { "spaceSync.healthConsentAsked.\(account)" }

    /// After the update: the health tier is waiting for the consent on this device.
    func healthWaiting() {
        guard hasHealthData() else { return }
        askIfDue()
    }

    /// Health or Nutrition was opened.
    func healthUsed() {
        askIfDue()
    }

    private func askIfDue() {
        guard SpaceSyncFlag.isOn, let account, !consentGiven, !sending, !askingConsent,
              !defaults.bool(forKey: askedKey(account)) else { return }
        askingConsent = true
    }

    /// "Sync" or "Keep on this device". Asked once: an alert closed without an answer (the app
    /// quit) asks again.
    func answerConsent(_ yes: Bool) {
        askingConsent = false
        if let account { defaults.set(true, forKey: askedKey(account)) }
        if yes { setConsent(true) }
    }

    /// The switch in Settings, and the screen's yes: the service first (`PUT`/`DELETE
    /// /v2/consents/health`), then the engine (`MoveOver`). Nothing changes here unless the service
    /// has it; a failure leaves the switch as it was.
    func setConsent(_ on: Bool) {
        guard !sending, account != nil else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            guard await BananaAccount.shared.setHealthConsent(on, version: Self.consentVersion) else {
                PlaybackDiagnostics.shared.log("☁️ space", "the Health consent didn't reach the service; nothing changed")
                return
            }
            if on {
                await MoveOver.grantHealthConsent()
            } else {
                await MoveOver.withdrawHealthConsent()
            }
            consentGiven = on
            PlaybackDiagnostics.shared.log("☁️ space", on ? "Health consent given" : "Health consent withdrawn")
        }
    }

    // MARK: - Another account

    private(set) var accountChange: (from: String, to: String)?
    private func declinedKey(_ account: String) -> String { "spaceSync.accountChangeDeclined.\(account)" }

    /// Another account signed in where the mirror is `from`'s: asked once per new account. True
    /// when it's asked now; false when the person already said no for this account.
    @discardableResult
    func accountChanged(from old: String, to new: String) -> Bool {
        guard !defaults.bool(forKey: declinedKey(new)) else {
            declinedChange = (old, new)
            return false
        }
        accountChange = (old, new)
        askingAccountChange = true
        return true
    }

    /// "Clear" or "Don't sync".
    func answerAccountChange(clear: Bool) {
        askingAccountChange = false
        guard let change = accountChange else { return }
        accountChange = nil
        if clear {
            SpaceSyncLaunch.clearDeviceThenStart(from: change.from, to: change.to)
        } else {
            defaults.set(true, forKey: declinedKey(change.to))
            declinedChange = change
            PlaybackDiagnostics.shared.log("☁️ space", "another account: the person chose not to sync it here")
        }
    }

    /// Settings' "Sync this device": the question again, for the account declined before.
    func askAgain() {
        guard let change = declinedChange else { return }
        defaults.removeObject(forKey: declinedKey(change.to))
        declinedChange = nil
        accountChanged(from: change.from, to: change.to)
    }
}
