#if BANANA_AI
#if DEBUG
import Foundation

/// Runs in the actual app graph with real local Apple inference and the real Notes store.
/// The isolated PiDevelopment flavor keeps its data separate from main and Beta.
@MainActor
enum AssistantVerification {
    private static var started = false
    private static var headlessScheduled = false
    static func scheduleHeadlessIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--assistant-verify"), args.contains("--assistant-headless"), !headlessScheduled else { return }
        headlessScheduled = true
        Task {
            let assistant = AssistantStore.shared
            assistant.activate()
            await runIfRequested(assistant)
        }
    }
    static let runIdentifier: String = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--assistant-verification-id"), index + 1 < args.count else { return UUID().uuidString }
        return args[index + 1]
    }()
    static func runIfRequested(_ assistant: AssistantStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--assistant-verify"), !started else { return }
        started = true
        #if PI_DEVELOPMENT
        if ProcessInfo.processInfo.arguments.contains("--assistant-sample-verify") {
            await PiSampleDataVerification.run(assistant)
            return
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--assistant-workspace-verify") {
            await AssistantWorkspaceVerification.run(assistant)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--assistant-nutrition-verify") {
            await AssistantNutritionVerification.run(assistant)
            return
        }
        print("PI_APP_VERIFICATION starting")
        fflush(stdout)
        var report: [String: Any] = ["passed": false, "bundle": Bundle.main.bundleIdentifier ?? "", "model": "apple-foundation/on-device", "run": runIdentifier]
        let text = "Pi integration note " + UUID().uuidString.prefix(6)
        do {
            try requireIsolatedBuild()
            try await wait { assistant.available && assistant.selected != nil }
            report["model"] = assistant.modelIdentity
            await assistant.stop()
            try await wait { !assistant.busy }
            await assistant.newConversation()
            guard await assistant.send("Create one Banana note with this exact text: \"\(text)\". Prepare it for review without saving.") else {
                throw AssistantFailure(message: assistant.error ?? "Input was not admitted")
            }
            try await wait {
                !assistant.busy && assistant.workspace?.action?.kind == .note
            }
            guard let draft = assistant.workspace?.action, let draftID = UUID(uuidString: draft.id),
                  draft.notes == text, !VoiceNoteStore.shared.notes.contains(where: { $0.id == draftID }) else {
                throw AssistantFailure(message: "A generated note must remain a review draft until Save")
            }
            try VoiceNoteStore.shared.addAssistantNote(id: draftID, text: draft.notes!)
            report["noteReviewedBeforeSave"] = true
            let matches = VoiceNoteStore.shared.notes.filter { $0.transcript?.contains(text) == true }
            guard matches.count == 1, let note = matches.first else {
                throw AssistantFailure(message: "Expected one native note; found \(matches.count)")
            }
            let readRequest: [String: Any] = ["name": "read_note", "arguments": ["id": note.id.uuidString]]
            let readResult = try AssistantCapabilities.execute(String(decoding: try JSONSerialization.data(withJSONObject: readRequest), as: UTF8.self))
            guard readResult.contains(note.id.uuidString) else { throw AssistantFailure(message: "The note reader could not find the created note") }
            let listRequest: [String: Any] = ["name": "list_notes", "arguments": ["limit": 10]]
            let listResult = try AssistantCapabilities.execute(String(decoding: try JSONSerialization.data(withJSONObject: listRequest), as: UTF8.self))
            guard listResult.contains(note.id.uuidString) else { throw AssistantFailure(message: "The note list omitted the newly created note") }
            let request: [String: Any] = ["name": "create_note", "operationId": note.id.uuidString,
                                         "arguments": ["text": note.transcript ?? text]]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            _ = try AssistantCapabilities.execute(raw)
            guard VoiceNoteStore.shared.notes.filter({ $0.id == note.id }).count == 1 else {
                throw AssistantFailure(message: "Native operation was duplicated")
            }
            let storeFile = VoiceNoteStore.audioDirectory.appendingPathComponent("notes.json")
            let saved = try JSONDecoder().decode([VoiceNote].self, from: Data(contentsOf: storeFile))
            guard saved.filter({ $0.id == note.id }).count == 1 else { throw AssistantFailure(message: "Native note was not durably saved") }
            let conversation = assistant.selected
            let originalMessages = assistant.messages
            try await assistant.verifyColdReopen()
            try await wait { !assistant.busy && !assistant.messages.isEmpty }
            guard assistant.selected == conversation, assistant.messages == originalMessages else {
                throw AssistantFailure(message: "Cold reopen changed the conversation history")
            }
            guard VoiceNoteStore.shared.notes.filter({ $0.id == note.id }).count == 1 else {
                throw AssistantFailure(message: "Cold reopen repeated the native effect")
            }
            report["passed"] = true
            report["conversationId"] = conversation
            report["historyRestored"] = true
            report["nativeNotePersisted"] = true
            report["nativeOperationDeduplicated"] = true
            report["nativeNoteCount"] = 1
            report["noteReadAndListVerified"] = true
            report["messageCount"] = originalMessages.count
            report["errorMessages"] = assistant.messages.filter { $0.role == "error" }.map(\.text)
            await assistant.newConversation()
            guard await assistant.send("Use read_note to read the Banana note with ID \(note.id.uuidString). Tell me its exact text.") else {
                throw AssistantFailure(message: assistant.error ?? "Readback input was not admitted")
            }
            try await wait { !assistant.busy && assistant.messages.contains { $0.role == "assistant" } }
            guard assistant.messages.contains(where: { $0.role == "activity" && $0.text == "Reading a note" }),
                  assistant.messages.contains(where: { $0.role == "assistant" && $0.text.contains(text) }) else {
                throw AssistantFailure(message: "The local model did not read back the saved note")
            }
            report["modelReadbackVerified"] = true
            await assistant.newConversation()
            try await sendAndWait("For this conversation only, the secret word is Blueberry. Do not save it as a note. Reply only OK.", assistant)
            let largeLocalContext = assistant.modelIdentity.hasPrefix("mac-local/")
            if largeLocalContext {
                // The same short conversation no longer fills the Mac model's
                // 32K window. Exercise public manual compaction without pretending
                // it was an automatic threshold crossing. Verification config
                // keeps zero recent tokens so the short history has an old prefix.
                await assistant.compact()
                try await wait {
                    !assistant.busy && assistant.messages.contains(where: { $0.text == "Summarized earlier context" })
                }
                report["compactionVerificationKeepRecentTokens"] = 0
            } else {
                for index in 0..<7 {
                    if assistant.messages.contains(where: { $0.text == "Summarized earlier context" }) { break }
                    let background = String(repeating: "The orchard has apples, pears and plums. ", count: 70)
                    try await sendAndWait("Checkpoint \(index). Background reference only; do not create a note. Reply only OK. " + background, assistant)
                }
            }
            guard assistant.messages.contains(where: { $0.text == "Summarized earlier context" }) else {
                throw AssistantFailure(message: "The conversation did not compact")
            }
            try await sendAndWait("What was the secret word? Answer only that word.", assistant)
            guard assistant.messages.last(where: { $0.role == "assistant" })?.text.lowercased().contains("blueberry") == true else {
                throw AssistantFailure(message: "The compacted conversation lost the secret word")
            }
            report[largeLocalContext ? "manualContextCompaction" : "automaticContextCompaction"] = true
            report["recallAfterCompaction"] = true
            await assistant.newConversation()
            try await sendAndWait("Hello", assistant)
            let greeting = assistant.messages.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !greeting.isEmpty, greeting != "ok", greeting != "ok.", !greeting.contains("blueberry"),
                  !assistant.messages.contains(where: { $0.role == "activity" }) else {
                throw AssistantFailure(message: "A fresh greeting used tools or retained earlier conversation instructions")
            }
            report["freshConversationGreeting"] = true
            try await sendAndWait("Show my latest notes.", assistant)
            guard assistant.messages.contains(where: { $0.role == "activity" && $0.text == "Looking up notes" }),
                  assistant.messages.last(where: { $0.role == "assistant" })?.text.contains(text) == true else {
                throw AssistantFailure(message: "The natural-language notes query did not describe the saved note")
            }
            report["naturalNotesQuery"] = true
            #if os(macOS) && PI_DEVELOPMENT
            if largeLocalContext {
                await assistant.newConversation()
                try await sendAndWait("Using only these numbers, three meals have 37, 24, and 29 grams of protein. How many grams total, and how many calories from that protein at 4 kcal per gram? Do not look up app data. Be concise.", assistant)
                let answer = assistant.messages.last(where: { $0.role == "assistant" })?.text ?? ""
                guard answer.contains("90"), answer.contains("360"), !assistant.messages.contains(where: { $0.role == "activity" }) else {
                    throw AssistantFailure(message: "The local model failed the calculation or unnecessarily used app tools.")
                }
                report["localReasoningWithoutAppTools"] = true
                await assistant.newConversation()
                guard await assistant.send("Write a detailed 5000-word explanation of how stars evolve. Use your general knowledge and no app tools.") else {
                    throw AssistantFailure(message: "Cancellation input was not accepted.")
                }
                try await waitAsync { try await MacLocalInference.shared.activeRequestCount() > 0 }
                let stopped = Date()
                await assistant.stop()
                try await wait { !assistant.busy }
                try await waitAsync { try await MacLocalInference.shared.activeRequestCount() == 0 }
                report["cancelMilliseconds"] = Int(Date().timeIntervalSince(stopped) * 1000)
                report["nativeInferenceCancellation"] = true
                await assistant.newConversation()
                try await sendAndWait("Hello", assistant)
                report["nextInputAfterCancellation"] = true
            }
            #endif
            report["passed"] = true
        } catch {
            report["passed"] = false
            report["error"] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report["messages"] = assistant.messages.map { ["role": $0.role, "text": $0.text] }
        }
        await assistant.stop()
        for note in VoiceNoteStore.shared.notes.filter({ $0.transcript == text }) {
            VoiceNoteStore.shared.delete(note.id)
            report["testNoteCleanedUp"] = true
        }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL("pi-app-integration.json"), options: .atomic)
        } catch { print("Could not save Pi integration result: \(error)") }
        print("PI_APP_INTEGRATION \(report["passed"] ?? false)")
        fflush(stdout)
        finishHeadless(passed: report["passed"] as? Bool == true)
    }

    static func finishHeadless(passed: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--assistant-headless") else { return }
        #if os(macOS) && PI_DEVELOPMENT
        MacLocalInference.shared.stop()
        #endif
        exit(passed ? 0 : 1)
    }

    static func requireIsolatedBuild() throws {
        #if !PI_DEVELOPMENT
        throw AssistantFailure(message: "Real integration verification requires the isolated PiDevelopment configuration.")
        #endif
    }

    static func reportURL(_ name: String) throws -> URL {
        #if os(macOS)
        let directory = AppSupport.directory.appendingPathComponent("PiVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return directory.appendingPathComponent(name)
    }

    private static func sendAndWait(_ text: String, _ assistant: AssistantStore) async throws {
        let count = assistant.messages.filter { $0.role == "assistant" }.count
        guard await assistant.send(text) else { throw AssistantFailure(message: assistant.error ?? "Input was not admitted") }
        try await wait { !assistant.busy && assistant.messages.filter { $0.role == "assistant" }.count > count }
        if let error = assistant.messages.last(where: { $0.role == "error" }) {
            throw AssistantFailure(message: "The local model reported an error: " + error.text)
        }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(75)
        while !predicate() {
            guard Date() < deadline else { throw AssistantFailure(message: "Timed out waiting for the integrated assistant") }
            try await Task.sleep(for: .milliseconds(75))
        }
    }
    private static func waitAsync(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw AssistantFailure(message: "Timed out waiting for the inference worker") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Driven by run-app-lifecycle-device.py using real UIKit transitions. The model
/// waits deterministically; the production host, lifecycle and Pi journal run normally.
@MainActor
enum AssistantLifecycleVerification {
    private static var started = false
    static func runIfRequested(_ assistant: AssistantStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--assistant-lifecycle-verify"), !started else { return }
        started = true
        var report: [String: Any] = ["passed": false, "bundle": Bundle.main.bundleIdentifier ?? "", "run": AssistantVerification.runIdentifier]
        do {
            try AssistantVerification.requireIsolatedBuild()
            guard assistant.isDiagnostic else { throw AssistantFailure(message: "Lifecycle verification requires isolated diagnostics") }
            try await wait { assistant.available && assistant.selected != nil }
            await assistant.newConversation()
            let input = "Save then wait: Pi lifecycle fixture"
            guard await assistant.send(input) else { throw AssistantFailure(message: "Lifecycle input was not admitted") }
            try await wait { assistant.busy && assistant.fixtureNoteCount == 1 }
            let conversation = assistant.selected
            try await wait { assistant.verificationResumedBackgrounds > 0 }
            guard assistant.verificationClosedResources == ["databases": 0, "timers": 0, "modelRequests": 0] else {
                throw AssistantFailure(message: "Backgrounding left Pi resources open")
            }
            guard assistant.selected == conversation, assistant.fixtureNoteCount == 1,
                  assistant.messages.filter({ $0.role == "user" && $0.text == input }).count == 1 else {
                throw AssistantFailure(message: "Foreground recovery repeated or lost committed work")
            }
            await assistant.stop()
            try await wait { !assistant.busy }
            guard await assistant.send("Ready after foreground") else { throw AssistantFailure(message: "Foreground input was not admitted") }
            try await wait { !assistant.busy && assistant.messages.contains { $0.text == "Local reply: Ready after foreground" } }
            report["passed"] = true
            report["backgroundResources"] = assistant.verificationClosedResources
            report["conversationRestored"] = true
            report["nativeEffectCount"] = assistant.fixtureNoteCount
            report["foregroundCancellationAndNextInput"] = true
        } catch {
            report["error"] = error.localizedDescription
        }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: AssistantVerification.reportURL("pi-app-lifecycle.json"), options: .atomic)
        print("PI_APP_LIFECYCLE \(report["passed"] ?? false)")
        fflush(stdout)
        AssistantVerification.finishHeadless(passed: report["passed"] as? Bool == true)
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(75)
        while !predicate() {
            guard Date() < deadline else { throw AssistantFailure(message: "Timed out waiting for integrated app lifecycle") }
            try await Task.sleep(for: .milliseconds(75))
        }
    }
}
#endif

#endif
