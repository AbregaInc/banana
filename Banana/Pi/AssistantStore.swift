#if BANANA_AI
import Combine
import Foundation
import JavaScriptCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AssistantMessage: Decodable, Identifiable, Equatable {
    var id: String
    var role: String
    var text: String
    var agenda: AssistantAgenda? = nil
}

/// Schedule presentation uses native dates, never model-generated clock conversions.
struct AssistantAgenda: Decodable, Equatable {
    struct Item: Decodable, Equatable {
        var title: String
        var start: String
        var end: String
        var kind: String
        var hasScheduledTime: Bool?
        var startTimeZone: String? = nil
        var endTimeZone: String? = nil
    }
    var date: String
    var timeZone: String
    var items: [Item]
    var hasMore: Bool
    var sampleData: Bool?

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    var zoneLabel: String { zone.localizedName(for: .generic, locale: .current) ?? timeZone }
    var heading: String {
        let calendar = AssistantNutrition.calendar(zone)
        guard let day = try? AssistantNutrition.date(date, calendar: calendar) else { return date }
        let formatter = DateFormatter(); formatter.timeZone = zone
        formatter.dateStyle = .full; formatter.timeStyle = .none
        return formatter.string(from: day)
    }
    func sourceTime(_ instant: String, zoneID: String?) -> String? {
        guard let zoneID, let sourceZone = TimeZone(identifier: zoneID),
              let date = try? Date(instant, strategy: .iso8601) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = sourceZone; formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date) + " · " + zoneID
    }
    func time(_ item: Item, locale: Locale = .current) -> String {
        if item.kind == "allDay" { return "All day" }
        if item.hasScheduledTime == false { return "Any time" }
        guard let start = try? Date(item.start, strategy: .iso8601) else { return "Time unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        formatter.dateStyle = AssistantNutrition.key(start, calendar: calendar) == date ? .none : .short
        formatter.timeStyle = .short
        let first = formatter.string(from: start)
        guard let end = try? Date(item.end, strategy: .iso8601), end > start else { return first }
        let crossesOffset = zone.secondsFromGMT(for: start) != zone.secondsFromGMT(for: end)
        formatter.dateStyle = AssistantNutrition.key(end, calendar: calendar) == date ? .none : .short
        let last = formatter.string(from: end)
        return first + (crossesOffset ? " " + (zone.abbreviation(for: start) ?? "") : "")
            + " – " + last + (crossesOffset ? " " + (zone.abbreviation(for: end) ?? "") : "")
    }
}
struct AssistantConversation: Decodable, Identifiable, Equatable {
    var id: String
    var title: String
}
struct AssistantAvailability: Decodable {
    var available: Bool
    var reason: String
    var contextWindow: Int
    var modelName: String?
}
private struct AssistantSnapshot: Decodable {
    var selected: String
    var conversations: [AssistantConversation]
    var messages: [AssistantMessage]
    var busy: Bool
    var hasEarlier: Bool
    var hasMoreConversations: Bool
    var availability: AssistantAvailability
    var error: String?
    var surface: AssistantNutritionSurface?
    var workspace: AssistantWorkspaceState?
}

/// SwiftUI state is a view of Pi's durable records. Pi owns conversations and execution.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()
    @Published private(set) var conversations: [AssistantConversation] = []
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var selected: String?
    @Published private(set) var busy = false
    @Published private(set) var sending = false
    @Published private(set) var available = false
    @Published private(set) var loadingLocalModel = false
    @Published private(set) var availabilityReason = "Checking Apple Intelligence…"
    @Published private(set) var hasEarlier = false
    @Published private(set) var hasMoreConversations = false
    @Published private(set) var workspace: AssistantWorkspaceState?
    @Published private(set) var surface: AssistantNutritionSurface?
    @Published private(set) var updatingSurface = false
    @Published var error: String?
    /// Notes Pi saved, by conversation, in order: the conversation shows each as the note it
    /// is (its words, a way to it), not only as a "Saved a note" step.
    @Published private(set) var savedNotes: [String: [SavedNote]] = [:]
    #if DEBUG
    @Published private(set) var fixtureNoteCount = 0
    var isDiagnostic: Bool { diagnostic }
    private(set) var verificationBackgrounds = 0
    private(set) var verificationActivations = 0
    private(set) var verificationResumedBackgrounds = 0
    private(set) var verificationClosedResources: [String: Int] = [:]
    #endif
    private var host: AppleRuntimeHost?
    private var active = false
    private var started = false
    private var retryingInput = false
    private var transitions: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var diagnostic = false
    /// Whether the running Pi was started on the Mac's own model (vs Apple's, while it downloads).
    private var hostUsesLocalModel = false
    var modelIdentity: String {
        #if os(macOS) && PI_DEVELOPMENT
        if !diagnostic, let local = MacLocalInference.shared.resolvedConfiguration() { return "mac-local/\(local.modelId)" }
        #endif
        return diagnostic ? "faux/faux-1" : "apple-foundation/on-device"
    }
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    private struct PendingInput: Codable { var conversation: String; var text: String; var requestId: String }
    private var directory: URL {
        AppSupport.directory.appendingPathComponent(diagnostic ? "PiDiagnostics" : "PiAssistant", isDirectory: true)
    }
    private var pendingURL: URL { directory.appendingPathComponent("pending-input.json") }
    private var fixtureDirectory: URL { AppSupport.directory.appendingPathComponent("PiDiagnosticNotes", isDirectory: true) }
    private var selectionKey: String {
        if AppSupport.isPiVerification { return "assistant.verification.selection" }
        return diagnostic ? "assistant.test.selection" : "assistant.selection"
    }

    private init() {
        #if DEBUG
        diagnostic = (ProcessInfo.processInfo.arguments.contains("--assistant-test") || ProcessInfo.processInfo.arguments.contains("--assistant-test-navigation"))
        if diagnostic && ProcessInfo.processInfo.arguments.contains("--assistant-reset") {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixtureDirectory)
            UserDefaults.standard.removeObject(forKey: selectionKey)
            UserDefaults.standard.removeObject(forKey: "assistant.test.draft")
            UserDefaults.standard.removeObject(forKey: Self.savedNotesKey(diagnostic: true))
        }
        #endif
        savedNotes = (UserDefaults.standard.dictionary(forKey: savedNotesKey) as? [String: [[String: String]]] ?? [:])
            .mapValues { $0.compactMap { SavedNote($0) } }
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBackgroundCleanup() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setActive(false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endBackgroundCleanup()
                if self?.started == true { self?.setActive(true) }
            }
        })
        #elseif os(macOS)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.host?.stop()
                #if PI_DEVELOPMENT
                MacLocalInference.shared.stop()
                #endif
            }
        })
        #endif
    }

    private func makeHost() throws -> AppleRuntimeHost {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try AppleRuntimeHost(databasePath: directory.appendingPathComponent("agent.sqlite").path) { [weak self] message, passed in
            if !passed { self?.error = message }
        }
        host.toolHandler = { [weak self] request in
            guard let self else { throw AssistantFailure(message: "The assistant is unavailable.") }
            if let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
               value["name"] as? String == "nutrition_view", let args = value["arguments"] as? [String: Any] {
                await WellnessStore.shared.whenLoaded()
                #if DEBUG
                if AppSupport.isPiUITest && WellnessStore.shared.meals.isEmpty { WellnessStore.shared.injectPreviewData() }
                #endif
                return try AssistantNutrition.validateRequest(args)
            }
            if let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
               value["name"] as? String == "app_workspace", let args = value["arguments"] as? [String: Any],
               let operation = value["operationId"] as? String {
                await WellnessStore.shared.whenLoaded()
                #if DEBUG
                if AppSupport.isPiUITest && WellnessStore.shared.meals.isEmpty { WellnessStore.shared.injectPreviewData() }
                #endif
                return String(decoding: try JSONEncoder().encode(AssistantWorkspace.prepare(args, operation: operation)), as: UTF8.self)
            }
            #if DEBUG
            if self.diagnostic {
                let result = try AssistantFixtureTools.execute(request, directory: self.fixtureDirectory)
                self.updateFixtureCount()
                self.recordSavedNote(request)
                return result
            }
            #endif
            if let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any], value["name"] as? String == "day_plan" {
                await OccurrenceStore.shared.recomputeIfStale(reason: "assistant day plan")
            }
            let result = try AssistantCapabilities.execute(request)
            self.recordSavedNote(request)
            return result
        }
        host.eventHandler = { [weak self] event in self?.receive(event) }
        var configuration: [String: Any] = ["testModel": diagnostic]
        #if os(macOS) && PI_DEVELOPMENT
        // The Mac's own model, kept by the app: Qwen through the app's Locals once `LocalModel`
        // has its files here and checked, Apple's on-device model until then. Never in
        // fixture/UI-test runs (no 3 GB download there).
        hostUsesLocalModel = false
        if !diagnostic {
            LocalModel.shared.start()
            if let local = MacLocalInference.shared.resolvedConfiguration() {
                configuration["localModel"] = local.agent
                hostUsesLocalModel = true
                if AppSupport.isPiVerification { configuration["compactionKeepRecentTokens"] = 0 }
                host.modelHandler = { try await MacLocalInference.shared.generate($0) }
                host.modelStatusHandler = { MacLocalInference.shared.status }
            }
        }
        #endif
        let config = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
        host.context.setObject(config, forKeyedSubscript: "nativeAgentConfiguration" as NSString)
        guard let bootstrap = Bundle.main.url(forResource: "pi-bootstrap", withExtension: "js"),
              let agent = Bundle.main.url(forResource: "pi-agent", withExtension: "js") else {
            throw AssistantFailure(message: "The assistant resources are missing from this build.")
        }
        try host.load(bootstrap: bootstrap, script: agent)
        return host
    }

    func activate() { started = true; setActive(true) }

    private func setActive(_ value: Bool) {
        let previous = transitions
        transitions = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                if value {
                    #if os(macOS) && PI_DEVELOPMENT
                    if !self.diagnostic {
                        LocalModel.shared.start()
                        let local = MacLocalInference.shared.resolvedConfiguration() != nil
                        // The model finished downloading since Pi started: start Pi again on it.
                        if self.host != nil, local != self.hostUsesLocalModel { self.host?.stop(); self.host = nil }
                        if local {
                            self.loadingLocalModel = true
                            self.availabilityReason = "Loading local model on this Mac…"
                            defer { self.loadingLocalModel = false }
                            try await MacLocalInference.shared.startIfConfigured()
                        }
                    }
                    #endif
                    if self.host?.isStopped == true { self.host?.stop(); self.host = nil }
                    if self.host == nil { self.host = try self.makeHost() }
                    self.active = true
                    _ = try await self.call("activate", ["selected": self.selected ?? UserDefaults.standard.string(forKey: self.selectionKey) ?? ""])
                    try await self.retryPendingInput()
                    #if DEBUG
                    self.verificationActivations += 1
                    self.verificationResumedBackgrounds = self.verificationBackgrounds
                    self.writeVerificationState()
                    #endif
                } else {
                    self.active = false
                    if let host = self.host { _ = try await host.request("deactivate") }
                    #if DEBUG
                    self.verificationBackgrounds += 1
                    self.verificationClosedResources = self.host?.resources ?? [:]
                    self.writeVerificationState()
                    #endif
                    #if os(iOS)
                    self.endBackgroundCleanup()
                    #endif
                }
            } catch {
                self.error = Self.message(error)
                if value {
                    self.available = false
                    self.availabilityReason = Self.message(error)
                }
                #if os(iOS)
                if !value { self.endBackgroundCleanup() }
                #endif
            }
        }
    }

    private func receive(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        if let state = try? JSONDecoder().decode(AssistantSnapshot.self, from: data) {
            conversations = state.conversations; messages = state.messages; selected = state.selected
            surface = state.surface; workspace = state.workspace
            busy = state.busy; available = state.availability.available
            if state.availability.available {
                availabilityReason = state.availability.modelName.map { "\($0) · On this Mac" } ?? "On this \(DeviceRole.current.name)"
            } else if state.availability.modelName != nil {
                availabilityReason = state.availability.reason
            } else if state.availability.reason == "requiresOS27" {
                #if os(iOS)
                availabilityReason = "Assistant requires iOS or iPadOS 27 or later."
                #else
                availabilityReason = "Assistant requires macOS 27 or later."
                #endif
            } else if state.availability.reason.contains("appleIntelligenceNotEnabled") {
                availabilityReason = "Enable Apple Intelligence in system settings to use Assistant."
            } else if state.availability.reason.contains("deviceNotEligible") {
                availabilityReason = "This device doesn’t support Apple Intelligence."
            } else if state.availability.reason.contains("modelNotReady") {
                availabilityReason = "Apple Intelligence is still preparing its on-device model. Try again when it’s ready."
            } else {
                availabilityReason = "The on-device model is unavailable. Check Apple Intelligence in system settings."
            }
            hasEarlier = state.hasEarlier; hasMoreConversations = state.hasMoreConversations
            if let message = state.error { error = message }
            UserDefaults.standard.set(state.selected, forKey: selectionKey)
            #if DEBUG
            if diagnostic { updateFixtureCount() }
            writeVerificationState()
            #endif
            if active, !busy, !retryingInput, FileManager.default.fileExists(atPath: pendingURL.path) {
                Task { [weak self] in try? await self?.retryPendingInput() }
            }
        } else if let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = state["error"] as? String {
            error = message
        }
    }

    private func call(_ operation: String, _ payload: [String: Any] = [:]) async throws -> String {
        guard let host else { throw AssistantFailure(message: "The assistant is not ready yet.") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return try await host.request(operation, payload: json)
    }

    func send(_ text: String) async -> Bool {
        guard active, available, !sending, !busy, let selected else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        sending = true; error = nil
        defer { sending = false }
        do {
            if FileManager.default.fileExists(atPath: pendingURL.path) {
                try await retryPendingInput()
                return false
            }
            let input = PendingInput(conversation: selected, text: trimmed, requestId: UUID().uuidString)
            try JSONEncoder().encode(input).write(to: pendingURL, options: .atomic)
            try await retryPendingInput()
            return true
        } catch { self.error = Self.message(error); return false }
    }

    private func retryPendingInput() async throws {
        guard active, !retryingInput, FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        retryingInput = true
        defer { retryingInput = false }
        let input = try JSONDecoder().decode(PendingInput.self, from: Data(contentsOf: pendingURL))
        _ = try await call("select", ["id": input.conversation])
        _ = try await call("send", ["text": input.text, "requestId": input.requestId])
        try FileManager.default.removeItem(at: pendingURL)
    }

    struct SavedNote: Equatable {
        let id: UUID, text: String
        init(id: UUID, text: String) { self.id = id; self.text = text }
        init?(_ raw: [String: String]) {
            guard let id = raw["id"].flatMap(UUID.init(uuidString:)), let text = raw["text"] else { return nil }
            self.init(id: id, text: text)
        }
    }

    private static func savedNotesKey(diagnostic: Bool) -> String {
        diagnostic ? "assistant.test.savedNotes" : "assistant.savedNotes"
    }
    private var savedNotesKey: String {
        #if DEBUG
        if diagnostic { return Self.savedNotesKey(diagnostic: true) }
        #endif
        return Self.savedNotesKey(diagnostic: false)
    }

    /// After a successful create_note: remember which note this conversation made.
    private func recordSavedNote(_ request: String) {
        guard let value = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              value["name"] as? String == "create_note", let selected,
              let id = (value["operationId"] as? String).flatMap(UUID.init(uuidString:)),
              let text = (value["arguments"] as? [String: Any])?["text"] as? String else { return }
        var list = savedNotes[selected] ?? []
        guard !list.contains(where: { $0.id == id }) else { return }
        list.append(SavedNote(id: id, text: text))
        savedNotes[selected] = list
        UserDefaults.standard.set(savedNotes.mapValues { $0.map { ["id": $0.id.uuidString, "text": $0.text] } }, forKey: savedNotesKey)
    }

    /// The note behind the `index`-th "Saving a note" step of the loaded messages, counted from
    /// the newest, so earlier pages not loaded yet don't shift the match.
    func savedNote(forNoteStepFromNewest index: Int) -> SavedNote? {
        guard let selected, let list = savedNotes[selected], index < list.count else { return nil }
        return list[list.count - 1 - index]
    }

    func newConversation() async { await perform("new") }
    func select(_ id: String) async { await perform("select", ["id": id]) }
    func stop() async { await perform("stop") }
    func loadEarlier() async { await perform("earlier") }
    func loadMoreConversations() async { await perform("moreConversations") }
    func compact() async { await perform("compact") }
    func updateSurface(_ patch: [String: Any]) async {
        guard active, !updatingSurface else { return }
        updatingSurface = true
        defer { updatingSurface = false }
        var patch = patch
        patch["revision"] = surface?.revision ?? 0
        await perform("surface", ["patch": patch, "requestId": UUID().uuidString])
    }
    func dismissWorkspace(actionID: String? = nil) async {
        guard actionID == nil || workspace?.action?.id == actionID else { return }
        await perform("workspace", ["fields": ["kind": "dismiss", "revision": workspace?.revision ?? 0], "requestId": UUID().uuidString])
    }
    func clearHistory() async {
        let previous = transitions
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                self.active = false
                if let host = self.host { _ = try await host.request("deactivate"); host.stop() }
                self.host = nil
                if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
                UserDefaults.standard.removeObject(forKey: self.selectionKey)
                self.selected = nil; self.messages = []; self.conversations = []; self.surface = nil; self.workspace = nil; self.busy = false
                self.host = try self.makeHost(); self.active = true
                _ = try await self.call("activate")
            } catch { self.error = Self.message(error) }
        }
        transitions = task
        await task.value
    }
    private func perform(_ operation: String, _ payload: [String: Any] = [:]) async {
        do { error = nil; _ = try await call(operation, payload) }
        catch { self.error = Self.message(error) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    #if DEBUG
    private func writeVerificationState() {
        guard ProcessInfo.processInfo.arguments.contains("--assistant-lifecycle-verify") else { return }
        let state: [String: Any] = ["run": AssistantVerification.runIdentifier, "active": active, "busy": busy, "selected": selected ?? "",
                                  "backgrounds": verificationBackgrounds, "activations": verificationActivations,
                                  "resources": host?.resources ?? [:], "fixtureNotes": fixtureNoteCount]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pi-app-lifecycle-state.json")
        try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    func verifyColdReopen() async throws {
        await transitions?.value
        let conversation = selected
        _ = try await call("deactivate")
        host?.stop(); host = nil; active = false
        messages = []; conversations = []; selected = nil
        host = try makeHost(); active = true
        _ = try await call("activate", ["selected": conversation ?? ""])
    }

    private func updateFixtureCount() {
        fixtureNoteCount = ((try? JSONDecoder().decode([VoiceNote].self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("fixture-notes.json")))) ?? []).count
    }
    #endif

    #if os(iOS)
    private func beginBackgroundCleanup() {
        guard host != nil, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save assistant work") { [weak self] in
            MainActor.assumeIsolated {
                self?.host?.stop(); self?.host = nil; self?.active = false
                self?.endBackgroundCleanup()
            }
        }
    }
    private func endBackgroundCleanup() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

#endif
