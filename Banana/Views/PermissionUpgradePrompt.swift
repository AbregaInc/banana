import SwiftUI

/// Reused by features when provider requirements grow; consent remains an explicit action.
struct PermissionUpgradePrompt: ViewModifier {
    let provider: String
    let explanation: String
    let needs: [PermissionUpgradeNeed]
    let upgrade: @MainActor ([PermissionUpgradeNeed]) async -> PermissionUpgradeOutcome
    @StateObject private var model = PermissionUpgradePromptModel()

    func body(content: Content) -> some View {
        content
            .onAppear { model.offer(needs) }
            .onChange(of: needs) { _, value in model.offer(value) }
            .alert(model.presentation?.retry == true ? "Access wasn’t updated" : "Update \(provider) access?",
                   isPresented: Binding(get: { model.presentation != nil }, set: { if !$0 { model.presentation = nil } }),
                   presenting: model.presentation) { value in
                Button(value.retry ? "Retry" : "Reconnect") {
                    Task { await model.update(value, using: upgrade) }
                }
                .accessibilityIdentifier("permission-upgrade.reconnect")
                Button("Not now", role: .cancel) { model.deferUpgrade(value) }
            } message: { value in
                Text(explanation + "\n\n" + Array(Set(value.needs.map(\.account))).sorted().joined(separator: "\n"))
            }
    }
}

#if !BANANA_PUBLIC
struct GooglePermissionUpgradePrompt: ViewModifier {
    @ObservedObject private var account = BananaAccount.shared
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var access = FeatureAccessStore.shared

    #if DEBUG && targetEnvironment(simulator)
    @State private var fixtureUpdated = false
    private var fixture: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--permission-upgrade-fixture"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    private var fixtureID: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--permission-upgrade-fixture-id"), args.indices.contains(index + 1) else { return "default" }
        return args[index + 1]
    }
    #endif

    private var needs: [PermissionUpgradeNeed] {
        #if DEBUG && targetEnvironment(simulator)
        if fixture != nil {
            if fixtureUpdated { return [] }
            return PermissionUpgradePolicy.missing(provider: "google", account: "noor@plan.example", granted: [],
                requirements: [PermissionRequirement(id: "contacts-" + fixtureID, title: "Contacts", scopes: ["contacts"])])
        }
        #endif
        guard modules.choice.includes(.email), access.allows("email") else { return [] }
        let requirement = PermissionRequirement(id: "sender-photos", title: "Contacts", scopes: Set(MailScopes.senderPhotos))
        return (account.account?.google ?? []).filter { $0.capabilities?.mailRead == true }.flatMap { link in
            PermissionUpgradePolicy.missing(provider: "google", account: link.email,
                granted: link.permissionScopes?["mail"], requirements: [requirement])
        }
    }

    func body(content: Content) -> some View {
        content.modifier(PermissionUpgradePrompt(provider: "Google",
            explanation: "Allow Contacts access to show sender photos.", needs: needs) { requested in
                #if DEBUG && targetEnvironment(simulator)
                if let fixture {
                    if fixture == "success" { fixtureUpdated = true; return .updated }
                    return fixture == "cancel" ? .cancelled : .failed
                }
                #endif
                for email in Set(requested.map(\.account)).sorted() {
                    await GoogleCalendarService.shared.reconnect(email: email)
                    if GoogleCalendarService.shared.lastError != nil { return .failed }
                }
                guard await account.refresh() else { return .failed }
                let remaining = needs
                return requested.contains { request in remaining.contains { $0.id == request.id } } ? .cancelled : .updated
            })
    }
}
#endif
