import CryptoKit
import Foundation

/// A model's files pinned by revision, size and SHA-256 (`Banana/Pi/Resources/pi-local-model.json`),
/// and the checks that say they are complete and untampered. Used by Banana Pi's Mac model
/// (`LocalModel`); nothing here is Mac-only, so iPhone and iPad can use it for a model of their own.
enum PinnedModelFiles {
    struct Manifest: Decodable {
        struct File: Decodable { let bytes: Int64; let sha256: String }
        /// How Locals serves it and how Pi sizes its turns.
        struct Profile: Decodable {
            let modelId: String
            let serverModel: String
            let name: String
            let port: Int
            let contextWindow: Int
            let maxTokens: Int
            let thinkingLevel: String
        }
        let repo: String
        let revision: String
        let files: [String: File]
        let profile: Profile
        var totalBytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }
        var name: String { profile.name }
    }


    /// One place, shared by every Banana Pi run (tests and verification included), named by its
    /// revision so a new pin downloads beside the old one rather than over it.
    static func folder(for manifest: Manifest, base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        let name = manifest.repo.split(separator: "/").last.map(String.init) ?? "model"
        return base.appendingPathComponent("Banana Pi/Models/\(name)@\(manifest.revision.prefix(12))", isDirectory: true)
    }

    /// Every file at its size and the revision stamped as checked: no 3 GB re-hash at launch.
    static func isChecked(_ manifest: Manifest, in folder: URL) -> Bool {
        guard let stamp = try? String(contentsOf: folder.appendingPathComponent(".checked"), encoding: .utf8),
              stamp == manifest.revision else { return false }
        return manifest.files.allSatisfy { name, file in size(of: folder.appendingPathComponent(name)) == file.bytes }
    }

    /// Marks the folder as checked against this revision.
    static func stamp(_ manifest: Manifest, in folder: URL) throws {
        try Data(manifest.revision.utf8).write(to: folder.appendingPathComponent(".checked"), options: .atomic)
    }

    /// Each file's SHA-256 against the pin, read in 8 MB pieces off the caller's actor. A file that
    /// doesn't match is deleted, so the next try fetches it again.
    static func verify(_ manifest: Manifest, in folder: URL) async throws {
        try await Task.detached(priority: .utility) {
            for (name, file) in manifest.files {
                let url = folder.appendingPathComponent(name)
                guard size(of: url) == file.bytes else { throw PinnedModelFailure("\(name) is incomplete") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: url)
                    throw PinnedModelFailure("\(name) didn’t match its checksum")
                }
            }
        }.value
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

struct PinnedModelFailure: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
