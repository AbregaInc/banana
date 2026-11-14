import Foundation
import Combine
import CryptoKit

/// Provider-neutral requirements. Unknown grant metadata is not evidence of missing access.
struct PermissionRequirement: Equatable {
    var id: String
    var title: String
    var scopes: Set<String>
}

struct PermissionUpgradeNeed: Equatable, Identifiable {
    var provider: String
    var account: String
    var requirement: PermissionRequirement
    var missing: Set<String>

    /// Stable across ordering and partial grants; a new requirement can prompt again.
    var id: String {
        let key = ([provider, account.lowercased(), requirement.id] + requirement.scopes.sorted()).joined(separator: "\n")
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PermissionUpgradePolicy {
    static func missing(provider: String, account: String, granted: [String]?,
                        requirements: [PermissionRequirement]) -> [PermissionUpgradeNeed] {
        guard let granted else { return [] }
        let held = Set(granted)
        return requirements.compactMap { requirement in
            let missing = requirement.scopes.subtracting(held)
            return missing.isEmpty ? nil : PermissionUpgradeNeed(provider: provider, account: account,
                                                                 requirement: requirement, missing: missing)
        }
    }
}

enum PermissionUpgradeOutcome { case updated, cancelled, failed }

@MainActor
final class PermissionUpgradePromptModel: ObservableObject {
    struct Presentation: Equatable, Identifiable {
        var needs: [PermissionUpgradeNeed]
        var retry = false
        var id: String { needs.map(\.id).joined(separator: ":") + (retry ? ":retry" : "") }
    }
    @Published var presentation: Presentation?
    @Published private(set) var updating = false
    private var offered: [PermissionUpgradeNeed] = []
    private var queued: Presentation?
    private var deferred: [String]
    private let defaults: UserDefaults
    private let key = "permissions.deferred-upgrades"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deferred = defaults.stringArray(forKey: key) ?? []
    }

    func offer(_ needs: [PermissionUpgradeNeed]) {
        offered = needs
        guard !updating else { return }
        let pending = needs.filter { !deferred.contains($0.id) }
        if pending.isEmpty { presentation = nil }
        else if let previous = presentation, previous.retry {
            let current = pending.filter { need in previous.needs.contains { $0.id == need.id } }
            presentation = current.isEmpty ? Presentation(needs: pending) : Presentation(needs: current, retry: true)
        } else { presentation = Presentation(needs: pending) }
    }

    func deferUpgrade(_ value: Presentation) {
        deferred = Array((deferred.filter { old in !value.needs.contains { $0.id == old } } + value.needs.map(\.id)).suffix(100))
        defaults.set(deferred, forKey: key)
        presentation = nil
        offer(offered)
    }

    @discardableResult
    func queue(_ value: Presentation) -> Bool {
        guard !updating else { return false }
        queued = value
        updating = true
        presentation = nil
        return true
    }

    func update(_ value: Presentation, using action: @escaping @MainActor ([PermissionUpgradeNeed]) async -> PermissionUpgradeOutcome) async {
        guard queue(value) else { return }
        await completeDismissal(using: action)
    }

    /// The native sheet calls this only after dismissal; offers can update while it closes.
    func completeDismissal(using action: @escaping @MainActor ([PermissionUpgradeNeed]) async -> PermissionUpgradeOutcome) async {
        guard let value = queued else { return }
        queued = nil
        let current = value.needs.filter { need in offered.contains { $0.id == need.id } }
        guard !current.isEmpty else { updating = false; presentation = nil; offer(offered); return }
        let outcome = await action(current)
        updating = false
        switch outcome {
        case .updated:
            offered.removeAll { need in current.contains { $0.id == need.id } }
            offer(offered)
        case .cancelled:
            deferUpgrade(Presentation(needs: current))
        case .failed:
            let pending = offered.filter { need in current.contains { $0.id == need.id } }
            presentation = pending.isEmpty ? nil : Presentation(needs: pending, retry: true)
        }
    }
}
