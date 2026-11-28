#if !BANANA_PUBLIC
import Foundation

enum MailDraftAssistant {
    struct Unavailable: Error {}
    typealias NeedsInput = MailDraftWorkflow.NeedsInput

    static var isAvailable: Bool { ShellAssistant.isAvailable }

    /// Keep the backend fixed for this request, including evidence continuations. Only
    /// same-device providers receive composer mail. A paired chat grant is not a mail grant.
    @MainActor
    static func write(instruction: String, context: MailComposerModel.AssistantDraftContext,
                      body: String, source: MailLiveSource? = nil, thinking: MailAIThinking = .off,
                      model: MailAIModel? = nil,
                      generate selectedProvider: (([String: Any]) async throws -> String)? = nil) async throws -> String {
        let outcome = try await reply(instruction: instruction, context: context, body: body, source: source,
                                      thinking: thinking, model: model, generate: selectedProvider)
        switch outcome {
        case .draft(let text): return text
        case .note(let note): throw NeedsInput(message: note)
        case .noReply(let reason): throw NeedsInput(message: reason.isEmpty ? "This email doesn’t need a reply." : reason)
        case .questions(let picker): throw NeedsInput(message: picker.questions.map(\.question).joined(separator: " "))
        }
    }

    /// Drafts come from Banana's Pi with the banana-mail tools. A picker outcome carries the owner's
    /// questions for the composer. Manual drafts think off; the overnight pass passes .low.
    @MainActor
    static func reply(instruction: String, context: MailComposerModel.AssistantDraftContext,
                      body: String, source: MailLiveSource? = nil, thinking: MailAIThinking = .off,
                      model: MailAIModel? = nil,
                      generate selectedProvider: (([String: Any]) async throws -> String)? = nil) async throws -> MailAIOutcome {
        try await replyRun(instruction: instruction, context: context, body: body, source: source,
                           thinking: thinking, model: model, generate: selectedProvider).outcome
    }

    /// `reply` with how the outcome was made: the model, the thinking level and the tools that ran.
    @MainActor
    static func replyRun(instruction: String, context: MailComposerModel.AssistantDraftContext,
                         body: String, source: MailLiveSource? = nil, thinking: MailAIThinking = .off,
                         model: MailAIModel? = nil,
                         generate selectedProvider: (([String: Any]) async throws -> String)? = nil) async throws -> MailAIRun {
        #if BANANA_AI
        if #available(iOS 26.0, macOS 26.0, *) {
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  instruction.count <= 1000, body.count <= 3000 else { throw Unavailable() }
            let quoted = context.quote.flatMap(\.text).map { MailPlainText.string($0) } ?? ""
            let envelope = context.envelope
            if MailDraftWorkflow.isGeneralReply(instruction), body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let source, let conversation = context.conversation, let selected = context.selectedMessageID,
               let sender = context.sender, sender.account.lowercased() == conversation.account,
               envelope.mode == .reply, let header = envelope.selectedMessage, header.direction == .incoming,
               selected.account == conversation.account, header.account == conversation.account,
               header.threadID == conversation.thread, header.messageID == selected.message,
               !header.from.address.isEmpty, context.typedRecipients.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               context.recipients.flatMap({ $0 }).map({ $0.address.lowercased() }) == [header.from.address.lowercased()] {
                let question = MailDraftWorkflow.senderText(in: quoted, from: header.from.address)
                if let slot = MailCalendarReply.slot(in: question) {
                    do {
                        try source.checkComposerEvidenceAccess(for: conversation)
                        let available = try await AssistantCapabilities.composerIntervalAvailable(from: slot.start, to: slot.end, account: conversation.account)
                        try source.checkComposerEvidenceAccess(for: conversation)
                        return MailAIRun(outcome: .draft(available ? "My calendar for this account is clear for \(slot.label)." :
                            "I have a calendar conflict during \(slot.label)."), model: nil, thinking: thinking, tools: ["calendar": 1])
                    } catch is CancellationError { throw CancellationError() }
                    catch let failure as AssistantFailure { throw NeedsInput(message: failure.message) }
                    catch is MailAccessError { throw NeedsInput(message: "Reconnect the email account before writing this reply.") }
                    catch { throw NeedsInput(message: "Check the calendar for this account before replying with your availability.") }
                }
            }
            var read: ((MailDraftWorkflow.Lookup) async throws -> [MailDraftWorkflow.Evidence])?
            var recentHistory: (() async throws -> [MailDraftWorkflow.Evidence])?
            if let source, let conversation = context.conversation,
               let sender = context.sender, sender.account.caseInsensitiveCompare(conversation.account) == .orderedSame,
               let selected = context.selectedMessageID, selected.account == conversation.account {
                let audience = Set(context.recipients.flatMap { $0 }.map { $0.address.lowercased() })
                let audienceKnown = !audience.isEmpty && !audience.contains("") &&
                    !context.typedRecipients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                func evidence(_ lookup: MailDraftWorkflow.Lookup, precedingOnly: Bool = false) async throws -> [MailDraftWorkflow.Evidence] {
                    var query: String?, attachments = false, implicit = false, earlier = false, exact = false
                    switch lookup {
                    case .thread: break
                    case .attachments: attachments = true
                    case .earlierThreadAttachments:
                        earlier = true; implicit = true
                    case let .related(topic), let .relatedAttachments(topic), let .titledMail(topic), let .titledMailAttachments(topic):
                        if case .titledMail = lookup { exact = true }
                        if case .titledMailAttachments = lookup { exact = true; attachments = true }
                        if case .relatedAttachments = lookup { attachments = true }
                        query = topic
                        implicit = !instruction.localizedCaseInsensitiveContains(topic)
                    }
                    if implicit {
                        guard let message = envelope.selectedMessage,
                              message.account == conversation.account, message.threadID == conversation.thread,
                              message.messageID == selected.message, message.direction == .incoming,
                              [.reply, .replyAll].contains(envelope.mode) else {
                            throw NeedsInput(message: "Name the earlier email you want to use in your instructions.")
                        }
                        // An earlier one-to-one exchange with this sender can contain
                        // details that a new Cc recipient in this thread has never seen.
                        let ownAddresses = source.accounts.first(where: { $0.id == conversation.account })?
                            .identities.map { $0.address.lowercased() } ?? []
                        let priorAudience = Set(ownAddresses + [conversation.account.lowercased(), message.from.address.lowercased()])
                        guard audienceKnown, audience.isSubset(of: priorAudience) else {
                            throw NeedsInput(message: "Name the earlier email you want to use with these recipients.")
                        }
                    }
                    if lookup == .thread && !audienceKnown {
                        if precedingOnly { return [] }
                        throw NeedsInput(message: "Finish entering the recipients before using earlier messages.")
                    }
                    do {
                        let records = try await source.composerEvidence(for: conversation, selectedMessageID: selected.message, query: query,
                            includeAttachments: attachments, matchingParticipants: implicit, earlierThreadAttachments: earlier, exactTitle: exact,
                            threadAudience: lookup == .thread || earlier ? audience : nil)
                        return records.filter { item in
                            guard item.account == conversation.account else { return false }
                            switch (lookup, item.kind) {
                            case (.titledMailAttachments, "attachment"), (.relatedAttachments, "attachment"),
                                 (.titledMail, "relatedMessage"), (.related, "relatedMessage"):
                                return item.threadID != conversation.thread
                            case (.earlierThreadAttachments, "attachment"):
                                return item.threadID == conversation.thread && item.messageID != selected.message
                            case (.attachments, "attachment"):
                                return item.threadID == conversation.thread && item.messageID == selected.message
                            case (.thread, "selectedMessage"):
                                // The automatic history read may also carry earlier mail with the same
                                // correspondent from other threads; it is marked for independent verification.
                                if item.threadID != conversation.thread { return precedingOnly && item.recoveredThreadMessage }
                                return !precedingOnly || item.messageID != selected.message
                            default: return false
                            }
                        }.map { item in
                            let id = [item.kind, item.threadID, item.messageID, item.partID ?? "", item.filename ?? ""].map {
                                Data($0.utf8).base64EncodedString()
                            }.joined(separator: ".")
                            let kind: String
                            switch lookup {
                            case .earlierThreadAttachments: kind = "earlierThreadAttachment"
                            case .relatedAttachments, .titledMailAttachments: kind = "relatedAttachment"
                            default: kind = item.kind
                            }
                            return .init(id: id, kind: kind,
                                source: [item.isMine ? "Outgoing" : "Incoming", item.subject, item.sender, item.sent, item.filename].compactMap { $0 }.joined(separator: " · "),
                                text: item.text, coverage: item.coverage, recoveredThreadMessage: item.recoveredThreadMessage)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw NeedsInput(message: "Banana couldn’t read that mail. Add the relevant detail to your instructions.")
                    }
                }
                read = { try await evidence($0) }
                if let header = envelope.selectedMessage, header.account == conversation.account,
                   header.threadID == conversation.thread, header.messageID == selected.message {
                    recentHistory = { try await evidence(.thread, precedingOnly: true) }
                }
            }
            let suppliedText = [instruction, String(context.subject.prefix(300)), String(quoted.prefix(2400)), body].joined(separator: "\n")
            let empty: () async throws -> [MailDraftWorkflow.Evidence] = { [] }
            let tally = MailAIToolTally()
            let history = recentHistory ?? empty
            let tools = MailPiReply.Tools(
                readThread: { tally.add("read_thread"); return try await history() },
                search: { topic in tally.add("search_mail"); return try await read?(.related(topic)) ?? [] },
                attachments: { tally.add("read_attachments"); return try await read?(.attachments) ?? [] },
                checkReply: { draft, passages in
                    tally.add("check_reply")
                    try MailDraftPrompt.checkGrounding(in: draft, suppliedText: suppliedText, authorInstruction: instruction,
                                                       optionalThreadPassages: passages)
                    if MailOutgoingFileClaim.contradicts(body: draft, outgoingCount: context.outgoingAttachmentCount) {
                        throw MailPiReply.Failure(message: "The reply refers to a file on this email, but none is attached. Don't mention one.")
                    }
                },
                selectedText: quoted)
            let selected = envelope.selectedMessage
            let email = MailPiReply.Email(subject: context.subject, from: selected?.from.address ?? "",
                fromName: selected?.from.name, account: context.conversation?.account ?? context.sender?.account ?? "",
                to: envelope.to.map(\.address), cc: envelope.cc.map(\.address), text: quoted)
            let task = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? instruction
                : instruction + "\n\nMy draft so far (data):\n" + body
            let chosen = model ?? selectedProvider.map(MailAIModel.wrapping) ?? MailAIModel.current()
            let outcome: MailAIOutcome
            do {
                outcome = try await MailPiReply.run(task: task, email: email, tools: tools, model: chosen, thinking: thinking,
                    reasoningBudget: thinking == .off ? nil : 1024, checkAccess: {
                        guard let source, let conversation = context.conversation else { return }
                        do { try source.checkComposerEvidenceAccess(for: conversation) }
                        catch is CancellationError { throw CancellationError() }
                        catch { throw NeedsInput(message: "Reconnect the email account before writing this reply.") }
                    })
            } catch let failure as MailAIFailure {
                throw NeedsInput(message: failure.message)
            }
            if case .draft(let text) = outcome, MailOutgoingFileClaim.contradicts(body: text, outgoingCount: context.outgoingAttachmentCount) {
                throw NeedsInput(message: "The generated reply refers to a file on this email. Attach it or ask for a reply without it.")
            }
            return MailAIRun(outcome: outcome, model: chosen.modelId ?? chosen.provider, thinking: thinking, tools: tally.snapshot)
        }
        #endif
        throw Unavailable()
    }

    #if BANANA_AI
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    static func provider() -> ([String: Any]) async throws -> String {
        #if os(macOS)
        LocalModel.shared.start()
        if let config = MacLocalInference.shared.resolvedConfiguration(), MacLocalInference.shared.memoryAllows(config) {
            return { request in
                var local = request
                local["backend"] = "mac-local"
                local["modelId"] = config.modelId
                return try await MacLocalInference.shared.generate(encode(local))
            }
        }
        #endif
        return { try await AppleFoundationModel.generate(encode($0)) }
    }

    private static func encode(_ request: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }
    #endif
}
#endif
