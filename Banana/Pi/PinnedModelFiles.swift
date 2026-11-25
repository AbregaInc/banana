import CryptoKit
import Foundation

/// A model's files pinned by revision, size and SHA-256 (`Banana/Pi/Resources/pi-local-model.json`),
/// and the checks that say they are complete and untampered. Used by Banana Pi's Mac model
/// (`LocalModel`); nothing here is Mac-only, so iPhone and iPad can use it for a model of their own.
enum PinnedModelFiles {
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable { let bytes: Int64; let sha256: String }
        /// How Locals serves it and how Pi sizes its turns.
        struct Profile: Decodable, Sendable {
            let modelId: String
            let serverModel: String
            let name: String
            let port: Int
            /// Independently installed apps own separate loopback workers. Pi verification
            /// keeps the port in the model profile, including its existing benchmark tooling.
            var macWorkerPort: Int {
                #if PI_DEVELOPMENT
                port
                #elseif BANANA_DEVELOPMENT
                41794
                #elseif BANANA_BETA
                41793
                #else
                41792
                #endif
            }
            let contextWindow: Int
            let maxTokens: Int
            let thinkingLevel: String
        }
        let repo: String
        let revision: String
        let files: [String: File]
        let profile: Profile
        var installationID: String { "\(repo)@\(revision)" }

        var isCatalogSafe: Bool {
            let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
            let identifier = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$"#
            let filename = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\.(json|jinja|safetensors)$"#
            return parts.count == 2 && parts.allSatisfy { $0.range(of: identifier, options: .regularExpression) != nil }
                && revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
                && profile.modelId.range(of: identifier, options: .regularExpression) != nil
                && profile.serverModel.range(of: #"^locals/[A-Za-z0-9][A-Za-z0-9_.@-]{0,128}$"#, options: .regularExpression) != nil
                && !profile.name.isEmpty && profile.name.count <= 80
                && (4096...262_144).contains(profile.contextWindow)
                && (1..<max(1, profile.contextWindow)).contains(profile.maxTokens)
                && ["off", "low", "medium", "high", "xhigh"].contains(profile.thinkingLevel)
                && (1...128).contains(files.count) && files["config.json"] != nil
                && (files["model.safetensors"] != nil || files["model.safetensors.index.json"] != nil)
                && files.keys.contains { $0.hasSuffix(".safetensors") }
                && files.allSatisfy { name, file in
                    name.range(of: filename, options: .regularExpression) != nil
                        && (1...80_000_000_000).contains(file.bytes)
                        && file.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
                }
                && totalBytes <= 160_000_000_000
        }

        var verificationStamp: String {
            let pin = files.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.bytes):\($0.value.sha256)" }.joined(separator: "\n")
            let digest = SHA256.hash(data: Data("\(installationID)\n\(pin)".utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        var totalBytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }
        var name: String { profile.name }
    }


    /// One place, shared by every Banana Pi run (tests and verification included), named by its
    /// revision so a new pin downloads beside the old one rather than over it.
    static func folder(for manifest: Manifest, base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        let name = manifest.repo.split(separator: "/").last.map(String.init) ?? "model"
        return base.appendingPathComponent("Banana Pi/Models/\(name)@\(manifest.revision.prefix(12))", isDirectory: true)
    }

    /// Catalog pins have their own directory, so requalification cannot touch an active model.
    static func catalogFolder(for manifest: Manifest) -> URL {
        let legacy = folder(for: manifest)
        // Locals derives its API model ID from the final path component.
        return legacy.deletingLastPathComponent()
            .appendingPathComponent(manifest.verificationStamp, isDirectory: true)
            .appendingPathComponent(legacy.lastPathComponent, isDirectory: true)
    }

    /// Every file at its size and the revision stamped as checked: no 3 GB re-hash at launch.
    static func isChecked(_ manifest: Manifest, in folder: URL, allowLegacy: Bool = true) -> Bool {
        guard let stamp = try? String(contentsOf: folder.appendingPathComponent(".checked"), encoding: .utf8),
              stamp == manifest.verificationStamp || (allowLegacy && stamp == manifest.revision) else { return false }
        return manifest.files.allSatisfy { name, file in size(of: folder.appendingPathComponent(name)) == file.bytes }
    }

    /// Marks the folder as checked against this revision.
    static func stamp(_ manifest: Manifest, in folder: URL) throws {
        try Data(manifest.verificationStamp.utf8).write(to: folder.appendingPathComponent(".checked"), options: .atomic)
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
