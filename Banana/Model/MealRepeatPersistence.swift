import Foundation
import Darwin

/// Large encoding/writes happen before commit; the main actor only swaps one prepared file.
enum MealRepeatPersistence {
    static func cleanAbandonedStages(beside url: URL, before cutoff: Date = Date()) {
        let parent = url.deletingLastPathComponent()
        let folders = [parent, parent.appendingPathComponent("HealthStaging", isDirectory: true)]
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(".meal-"), name.hasSuffix(".tmp"),
                  UUID(uuidString: String(name.dropFirst(6).dropLast(4))) != nil,
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func stage(_ snapshot: WellnessSnapshot, beside url: URL) throws -> URL {
        let staged = try HealthFileProtection.stagingDirectory(beside: url).appendingPathComponent(".meal-" + UUID().uuidString + ".tmp")
        do {
            try JSONEncoder().encode(snapshot).write(to: staged, options: .atomic)
            try HealthFileProtection.exclude(staged)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func commit(_ staged: URL, replacing url: URL) throws {
        try HealthFileProtection.replace(staged, destination: url)
    }
}
