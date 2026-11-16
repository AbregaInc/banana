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
            .sheet(item: Binding(get: { model.presentation }, set: { value in
                if value == nil, !model.updating, let current = model.presentation { model.deferUpgrade(current) }
                else { model.presentation = value }
            }), onDismiss: {
                Task { await model.completeDismissal(using: upgrade) }
            }) { value in
                prompt(value)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
    }

    private func prompt(_ value: PermissionUpgradePromptModel.Presentation) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(value.retry ? "Access wasn’t updated" : "Update \(provider) access?")
                .font(.title2.weight(.semibold))
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(Set(value.needs.map(\.account))).sorted(), id: \.self) { account in
                Text(account).font(.callout).textSelection(.enabled)
            }
            HStack {
                Button("Not now", role: .cancel) { model.deferUpgrade(value) }
                    .buttonStyle(.bordered)
                Spacer()
                Button(value.retry ? "Retry" : "Reconnect") {
                    model.queue(value)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("permission-upgrade.reconnect")
            }
        }
        .padding(DS.Space.l)
        .frame(idealWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-upgrade.prompt")
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
                    guard await account.refresh() else { return .failed }
                    // Cancelling or declining one account ends the whole grouped request.
                    if needs.contains(where: { $0.account.lowercased() == email.lowercased() }) { return .cancelled }
                }
                return .updated
            })
    }
}
#endif
