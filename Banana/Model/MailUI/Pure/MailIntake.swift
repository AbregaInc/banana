#if !BANANA_PUBLIC
import Foundation

/// Where a file he is attaching waits between the system handing it over and the source keeping it:
/// a drop, a paste and the photo picker give a file that is only there for a moment, and the file
/// panel gives one that is his own and stays.
///
/// Nothing here runs on the main thread (`MailFiles` stops a Debug build that does file work
/// there), a file is copied a megabyte at a time and never held whole, and what is written is
/// written by the engine's door, `MailFiles`. The folder is the system's temporary directory,
/// never the app's data.
enum MailIntake {

    nonisolated static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BananaMailIntake", isDirectory: true)
    }

    /// Copies a file into a new folder of its own inside `directory`, under its safe name (or the
    /// safe form of `named`, for a file the system gave no name worth showing), and says where it is,
    /// what it is called and how big it is. Blocking: for a background thread.
    nonisolated static func copy(_ source: URL, into directory: URL, named: String? = nil,
                                 quarantine: MailQuarantine? = nil) throws -> (url: URL, name: String, bytes: Int) {
        let name = MailFileName.safe(named ?? source.lastPathComponent)
        let own = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let destination = own.appendingPathComponent(name)
        let temporary = try MailFiles.createTemporary(beside: destination)
        do {
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: temporary)
            defer { try? writer.close() }
            var total = 0
            while true {
                let chunk = try autoreleasepool { try reader.read(upToCount: 1 << 20) } ?? Data()
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
                total += chunk.count
            }
            try writer.close()
            try MailFiles.install(temporary: temporary, at: destination,
                                  protection: .completeUntilFirstUserAuthentication,
                                  quarantine: quarantine, durability: .atomic)
            return (destination, name, total)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Keeps a file the system lent for a moment, where it can wait. Nil if it could not be.
    nonisolated static func keep(_ offered: URL) async -> URL? {
        await Task.detached { try? copy(offered, into: folder).url }.value
    }

    /// Keeps bytes the system handed over as a picture (a screenshot on the Mac's pasteboard), under
    /// the name given. Nil if it could not be.
    nonisolated static func keep(_ data: Data, named name: String) async -> URL? {
        await Task.detached { () -> URL? in
            let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let destination = directory.appendingPathComponent(MailFileName.safe(name))
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try MailFiles.install(data, at: destination, protection: .completeUntilFirstUserAuthentication,
                                      quarantine: nil, durability: .atomic)
                return destination
            } catch {
                return nil
            }
        }.value
    }

    /// Whether a file is one `keep` made, and so one to clear away once the source has its own.
    nonisolated static func isKept(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Clears away a file `keep` made, and the folder it was in.
    nonisolated static func discard(_ kept: URL) async {
        guard isKept(kept) else { return }
        await Task.detached { try? FileManager.default.removeItem(at: kept.deletingLastPathComponent()) }.value
    }
}

#endif
