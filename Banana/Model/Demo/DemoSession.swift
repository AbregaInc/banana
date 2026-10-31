import Combine
import Foundation

@MainActor
final class DemoSession: ObservableObject {
    @Published private(set) var workspace: DemoWorkspace?
    @Published private(set) var error: String?
    @Published private(set) var saving = 0
    private var repository: DemoRepository?
    private var loading: Task<Void, Never>?
    private var retry: DemoCommand?
    private let directory: URL
    private let initial: DemoWorkspace
    private let io: DemoFileIO

    init(directory: URL? = nil, initial: DemoWorkspace? = nil, io: DemoFileIO = .live) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if BANANA_BETA
        let name = "Banana Beta Demo"
        #else
        let name = "Banana Demo"
        #endif
        var directory = directory ?? base.appendingPathComponent(name).appendingPathComponent(DemoRepository.directoryName)
        var fixture = initial ?? DemoFixtures.review()
        var io = io
        #if DEBUG
        // UI tests still enter through the public button. They can give that profile a stable
        // clock and a fresh container, never an arbitrary filesystem path or live service.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--demo-test-session"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("BananaDemoUITests")
                .appendingPathComponent(id.uuidString).appendingPathComponent(DemoRepository.directoryName)
        }
        if let index = arguments.firstIndex(of: "--demo-test-clock"), arguments.indices.contains(index + 1),
           let date = ISO8601DateFormatter().date(from: arguments[index + 1]) {
            let scenario = arguments.contains("--demo-empty") ? DemoFixtures.Scenario.empty : .review
            fixture = DemoFixtures.make(scenario, now: date, timeZone: TimeZone(identifier: "America/New_York")!)
        }
        if arguments.contains("--demo-save-failure") {
            let fault = DemoSaveFault()
            let underlying = io
            io = DemoFileIO(read: underlying.read, write: { bytes, url in
                try fault.beforeWrite()
                try underlying.write(bytes, url)
            })
        }
        #endif
        self.directory = directory
        self.initial = fixture
        self.io = io
    }

    func load() async {
        if let loading { await loading.value; return }
        let task = Task { @MainActor in
            do {
                let directory = self.directory, initial = self.initial, io = self.io
                let repository = try await DemoRepositories.open(directory: directory, initial: initial, io: io)
                self.repository = repository
                adopt(try await repository.open())
            } catch { self.error = error.localizedDescription }
        }
        loading = task
        await task.value
    }

    @discardableResult
    func perform(_ command: DemoCommand) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let repository else { error = "The demo is still opening. Please try again."; return false }
        saving += 1; defer { saving -= 1 }
        do {
            adopt(try await repository.apply(command))
            error = nil; retry = nil
            return true
        } catch {
            self.error = "Not saved. " + error.localizedDescription
            retry = command
            return false
        }
    }

    func retrySave() async { if let retry { await perform(retry) } }

    func reset() async {
        guard let repository else { return }
        saving += 1; defer { saving -= 1 }
        do { adopt(try await repository.reset()); error = nil; retry = nil }
        catch { self.error = "The demo was not reset. " + error.localizedDescription }
    }

    var canRetrySave: Bool { retry != nil }

    func clearError() { if workspace != nil { error = nil } }

    private func adopt(_ value: DemoWorkspace) {
        guard value.revision >= (workspace?.revision ?? 0) else { return }
        workspace = value
    }
}

/// One actor per profile even if Mac windows open the demo simultaneously. Re-entering while
/// an older view is releasing cannot create competing atomic-file writers.
@MainActor
private enum DemoRepositories {
    private static var opening: [URL: Task<DemoRepository, Error>] = [:]
    static func open(directory: URL, initial: DemoWorkspace, io: DemoFileIO) async throws -> DemoRepository {
        if let task = opening[directory] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try DemoRepository(directory: directory, initial: initial, io: io) }
        opening[directory] = task
        do { return try await task.value }
        catch { opening.removeValue(forKey: directory); throw error }
    }
}

#if DEBUG
private final class DemoSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func beforeWrite() throws {
        lock.lock(); defer { lock.unlock() }
        writes += 1
        // The seed succeeds. The first user command fails once; retry uses the same command/id.
        if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
    }
}
#endif
