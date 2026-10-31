import Foundation

/// A versioned replay file. It carries only fictional records and commands; no URL, credentials,
/// storage path or production capability can be supplied by a scenario.
struct DemoScenario: Codable, Sendable {
    var version = 1
    var name: String
    var clock: Date
    var timeZone: String
    var seed: DemoFixtures.Scenario = .review
    var commands: [DemoCommand]
}

struct DemoScenarioResult: Codable, Sendable {
    var name: String
    var completedCommands: Int
    var workspace: DemoWorkspace
}

enum DemoScenarioRunner {
    static func replay(_ scenario: DemoScenario, in directory: URL, io: DemoFileIO = .live) async throws -> DemoScenarioResult {
        guard scenario.version == 1, scenario.commands.count <= 1000,
              let zone = TimeZone(identifier: scenario.timeZone) else { throw DemoFailure.invalidData }
        let fixture = DemoFixtures.make(scenario.seed, now: scenario.clock, timeZone: zone)
        let repository = try DemoRepository(directory: directory, initial: fixture, io: io)
        var value = try await repository.open()
        guard value.anchor == fixture.anchor, value.timeZone == fixture.timeZone else { throw DemoFailure.invalidData }
        for command in scenario.commands { value = try await repository.apply(command) }
        return DemoScenarioResult(name: scenario.name, completedCommands: scenario.commands.count, workspace: value)
    }
}
