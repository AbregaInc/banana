#if os(macOS) && BANANA_AI && !BANANA_PUBLIC
import AppKit
import Foundation
import Combine
import os

@MainActor
final class MailOvernightDraftScheduler: ObservableObject {
    static let shared = MailOvernightDraftScheduler()
    private let defaults: UserDefaults
    private let suiteName: String?
    private let clock: @Sendable () -> Date
    nonisolated private static let enabledKey = "mailOvernightDraftAccounts"
    private let progressKey = "mailOvernightDraftProgress"
    @Published private(set) var accounts: Set<String>
    private var started = false
    private var timer: Task<Void, Never>?
    private var batch: Task<Void, Never>?
    private var wake: NSObjectProtocol?

    init(suiteName: String? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.suiteName = suiteName
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.clock = clock
        accounts = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
    }

    func setEnabled(_ enabled: Bool, account: String) {
        let key = account.lowercased()
        if enabled { accounts.insert(key) } else { accounts.remove(key) }
        defaults.set(accounts.sorted(), forKey: Self.enabledKey)
        batch?.cancel()
        if started { schedule() } else { start() }
    }

    func start() {
        guard !started else { return }
        started = true
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.schedule() } }
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        guard !accounts.isEmpty else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled, let self {
                let now = clock()
                let next: Date
                if let night = MailDraftNight.current(at: now) {
                    if self.batch == nil {
                        let job = Task(priority: .utility) { await self.run(night: night) }
                        self.batch = job
                        await job.value
                        self.batch = nil
                    }
                    next = min(night.end, clock().addingTimeInterval(15 * 60))
                } else {
                    next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 22, minute: 0),
                        matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
                }
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) }
                catch { return }
            }
        }
    }

    private func run(night: MailDraftNight) async {
        guard #available(macOS 26.0, *), !accounts.isEmpty, ModuleStore.shared.includes(.email),
              let session = await MailApplication.shared.readySession(), let source = session.source as? MailLiveSource else { return }
        let changes = ModuleStore.shared.objectWillChange
            .merge(with: session.navigation.$composer.dropFirst().map { _ in () }).eraseToAnyPublisher()
        await runPass(night: night, source: source, isEditing: { session.composer?.host == $0 },
            invalidations: changes, moduleEnabled: { ModuleStore.shared.includes(.email) }, makeProvider: MailDraftAssistant.provider)
    }

    /// The same pass is used by timer/wake callbacks and isolated store verification.
    @available(macOS 26.0, *)
    func runPass(night: MailDraftNight, source: MailLiveSource, isEditing: (MailConversationID) -> Bool,
                 invalidations: AnyPublisher<Void, Never>, moduleEnabled: () -> Bool, makeProvider: () -> (([String: Any]) async throws -> String),
                 makeWriter: (() -> MailAIModel)? = nil) async {
        let suite = suiteName
        let clock = self.clock
        for account in accounts.sorted() {
            // Store cursors and reviewed anchors per opted-in account. The same thread may
            // receive a new message later tonight, so the receipt identifies the message.
            let cursors = defaults.dictionary(forKey: progressKey) as? [String: Data] ?? [:]
            var scan = MailOvernightScan.resume(cursors[account], night: night)
            if let next = scan.notBefore, clock() < next { continue }
            func persist() {
                guard let data = try? JSONEncoder().encode(scan) else { return }
                var all = defaults.dictionary(forKey: progressKey) as? [String: Data] ?? [:]
                all[account] = data
                defaults.set(all, forKey: progressKey)
            }
            func enabled() -> Bool {
                !Task.isCancelled && accounts.contains(account) && clock() < night.end && moduleEnabled()
            }
            guard enabled() else { continue }
            do {
                let page = try await source.overnightCandidates(since: night.start.addingTimeInterval(-86400), limit: 12, accounts: [account], before: scan.before)
                for conversation in page.conversations {
                    guard enabled() else { return }
                    if isEditing(conversation.id) { continue }
                    guard let latest = conversation.messages.last, !scan.processed.contains(latest.id),
                          let identity = source.accounts.first(where: { $0.id == account && $0.state == .connected })?.identities.first(where: \.isDefault) else { continue }
                    let addresses = Set(source.accounts.flatMap { $0.identities.map { $0.address.lowercased() } } + [account])
                    let body = await source.body(latest.id)
                    guard body != .notOnDevice else { continue }
                    // Store definitive abstentions and successful reviews. A failed
                    // generation or a changing editor leaves the anchor retryable.
                    func reviewed() { scan.processed.insert(latest.id); persist() }
                    let provider = makeProvider()
                    let decision = try await MailAutomaticReplyEligibility.decide(conversation, ownerAddresses: addresses,
                        body: body, for: latest.id, generate: { request in
                            guard enabled(), !isEditing(conversation.id) else { throw CancellationError() }
                            try source.checkComposerEvidenceAccess(for: conversation.id)
                            let result = try await provider(request)
                            try source.checkComposerEvidenceAccess(for: conversation.id)
                            return result
                        })
                    guard case .candidate(let anchor) = decision,
                          anchor == latest.id else { reviewed(); continue }
                    let recipients = MailReplyRules.recipients(for: .reply(to: anchor), original: latest, myAddresses: addresses)
                    guard !recipients.to.isEmpty else { reviewed(); continue }
                    let context = Self.context(conversation, latest: latest, identity: identity, recipients: recipients, body: body)
                    // Overnight drafts think briefly. Questions, a note or a no-reply reason are kept
                    // for the morning, under the same checks as a draft.
                    let run: MailAIRun
                    do {
                        let writer = makeWriter?() ?? MailAIModel.current()
                        run = try await MailDraftAssistant.replyRun(instruction: "Draft a reply to the selected message.",
                            context: context, body: "", source: source, thinking: .low, model: writer)
                    } catch is MailDraftAssistant.NeedsInput { reviewed(); continue }
                    catch is MailDraftPrompt.UnverifiedLink { reviewed(); continue }
                    guard enabled(), !isEditing(conversation.id) else { continue }
                    // Reread through the local candidate path; opening a conversation would
                    // also request calendar preview resources. The store then compares the
                    // anchor and live draft state transactionally before creating anything.
                    guard let current = try await source.overnightConversation(conversation.id),
                          let last = current.messages.last,
                          last == latest, current.subject == conversation.subject else { continue }
                    let freshBody = await source.body(anchor)
                    guard enabled(), !isEditing(conversation.id), freshBody == body, MailAutomaticReplyEligibility.canRevalidate(current, ownerAddresses: addresses, body: freshBody, for: anchor) else { continue }
                    // Published UI state belongs to the main actor; the store's transaction
                    // runs off actor. Revoke this short-lived permit synchronously on a
                    // module or editor transition while the conditional save is suspended.
                    let permit = OSAllocatedUnfairLock(initialState: true)
                    let observation = invalidations.sink { permit.withLock { $0 = false } }
                    defer { observation.cancel() }
                    let isEnabled: @Sendable () -> Bool = {
                        let settings = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
                        return permit.withLock { $0 } && !Task.isCancelled && clock() < night.end &&
                            (settings.stringArray(forKey: Self.enabledKey) ?? []).contains(account)
                    }
                    let stored = MailAIStoredOutcome(run, anchor: anchor.message).data
                    let saved: Bool
                    if case .draft(let text) = run.outcome {
                        saved = try await source.saveOvernightDraft(body: text, for: conversation.id, anchor: anchor, isEnabled: isEnabled)
                        if saved, let stored { try? await source.recordOvernightOutcome(stored, for: conversation.id, anchor: anchor) }
                    } else if let stored {
                        saved = try await source.saveOvernightOutcome(stored, for: conversation.id, anchor: anchor, isEnabled: isEnabled)
                    } else { saved = false }
                    if saved { reviewed() }
                }
                if enabled() {
                    scan.before = page.next
                    scan.notBefore = clock().addingTimeInterval(15 * 60)
                    persist()
                }
            } catch is CancellationError { return }
            catch { continue } // A transient store or inference failure can retry in this window.
        }
    }

    private static func context(_ conversation: MailConversation, latest: MailMessage, identity: MailIdentity,
                                recipients: MailReplyRules.Recipients, body: MailBody) -> MailComposerModel.AssistantDraftContext {
        typealias Envelope = MailDraftPrompt.Envelope
        func party(_ p: MailPerson) -> Envelope.Party { .init(name: p.name, address: p.address) }
        let anchor = latest.id
        let header = Envelope.SelectedMessage(account: anchor.account, threadID: conversation.id.thread,
            messageID: anchor.message, direction: .incoming, from: party(latest.from), to: latest.to.map(party), cc: latest.cc.map(party))
        let envelope = Envelope(mode: .reply, from: .init(name: identity.name, address: identity.address),
            to: recipients.to.map(party), cc: recipients.cc.map(party), selectedMessage: header)
        return .init(draftID: nil, conversation: conversation.id, sender: identity,
            subject: MailReplyRules.subject(for: .reply(to: anchor), original: conversation.subject),
            quote: MailReplyRules.quote(message: latest, body: body, subject: conversation.subject, forward: false),
            recipients: [recipients.to, recipients.cc, []], typedRecipients: [], replyStyle: .reply,
            selectedMessageID: anchor, envelope: envelope, outgoingAttachmentCount: 0)
    }
}
#endif
