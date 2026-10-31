#if !BANANA_PUBLIC
import Foundation

/// Where a file came from, for the Mac's quarantine: the sender, as a `mailto:` URL
/// (MAIL-ENGINE 11.2). Nil origin quarantines the file without naming one.
struct MailQuarantine: Equatable, Sendable {
    var origin: URL?
    init(origin: URL? = nil) { self.origin = origin }
}

/// What can go wrong installing a file, said without saying anything about the file: no path,
/// no name, no text from the system's own message — only the step and the system's number
/// (invariant 21: what mail writes to a log carries no content, and a thrown error is
/// something a log line may be made from).
enum MailFileError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Step: String, Sendable { case create, move, protect, quarantine, backupExclusion, directory, sync }
    case failed(Step, code: Int)

    var description: String {
        switch self {
        case .failed(let step, let code): return "MailFileError.\(step.rawValue)(\(code))"
        }
    }
}

/// The calls that put attributes on files and directories, and the two that guard and settle
/// them, as closures, so that a test can record them and watch their *order* — which is the
/// whole point of several of them:
///
/// - A directory's protection class is set **before any store is opened**, so that SQLite's
///   `-wal` and `-shm` files, which SQLite creates on first write, are born with it.
/// - A file's protection class is set **after** it is moved into place, because a moved file
///   keeps the class it was created with, not the class of the directory it is moved to.
///
/// The Simulator does not enforce protection classes and may not report them, so the unit test
/// cannot read a class back; it reads the calls. Reading the real classes off a device is the
/// owner's first device run (D18).
struct MailFileAttributes: Sendable {
    /// Sets `type` as the protection class of the file or directory at `url`.
    var protect: @Sendable (_ url: URL, _ type: FileProtectionType) throws -> Void
    /// Marks `url` as excluded from backup.
    var excludeFromBackup: @Sendable (_ url: URL) throws -> Void
    /// Marks the file at `url` as having come from outside, on the Mac. Does nothing on iOS.
    var quarantine: @Sendable (_ url: URL, _ quarantine: MailQuarantine) throws -> Void
    /// Makes what is in the file or directory at `url` durable: the contents of a file, or the
    /// names in a directory (so that a rename into it is). A full sync — `F_FULLFSYNC`, which
    /// asks the drive to empty its own cache — and `fsync` where that is refused.
    var synchronize: @Sendable (_ url: URL) throws -> Void
    /// Requires that the caller is not on the main thread (invariant 10): files are written, moved
    /// and synced here, and a draft's attachment is megabytes. Called first by everything that
    /// does file work. The live one traps in Debug and carries on in Release. A closure of its own, not a call into the stores' guard, so that this file
    /// stands alone — the Mac's own checks compile it by itself (P21a).
    var requireOffMain: @Sendable () -> Void

    /// The real thing.
    static let live = MailFileAttributes(
        protect: { url, type in
            #if os(macOS)
            // Data protection classes are an iOS idea. The Mac's store is readable by any
            // program he runs, and the design says so (4.1, D17).
            _ = (url, type)
            #else
            do {
                try FileManager.default.setAttributes([.protectionKey: type], ofItemAtPath: url.path)
            } catch {
                throw MailFileError.failed(.protect, code: (error as NSError).code)
            }
            #endif
        },
        excludeFromBackup: { url in
            do {
                var url = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch {
                throw MailFileError.failed(.backupExclusion, code: (error as NSError).code)
            }
        },
        quarantine: { url, quarantine in
            #if os(macOS)
            do {
                var url = url
                var values = URLResourceValues()
                // `kLSQuarantineTypeKey`, `…AgentBundleIdentifierKey`, `…OriginURLKey` and
                // `kLSQuarantineTypeEmailAttachment`, spelled out because they live in
                // CoreServices and this file names Foundation only: a saved `.command` or `.pkg`
                // then meets Gatekeeper as a mail attachment.
                var properties: [String: Any] = [
                    "LSQuarantineType": "LSQuarantineTypeEmailAttachment",
                ]
                if let bundle = Bundle.main.bundleIdentifier {
                    properties["LSQuarantineAgentBundleIdentifier"] = bundle
                }
                if let origin = quarantine.origin {
                    properties["LSQuarantineOriginURL"] = origin
                }
                values.quarantineProperties = properties
                try url.setResourceValues(values)
            } catch {
                throw MailFileError.failed(.quarantine, code: (error as NSError).code)
            }
            #else
            _ = (url, quarantine)
            #endif
        },
        synchronize: { url in
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else { throw MailFileError.failed(.sync, code: Int(errno)) }
            defer { close(descriptor) }
            if fcntl(descriptor, F_FULLFSYNC) == -1 && fsync(descriptor) == -1 {
                throw MailFileError.failed(.sync, code: Int(errno))
            }
        },
        requireOffMain: {
            guard pthread_main_np() != 0 else { return }
            // In Debug, and so in the unit tests, work on the main thread stops the process where it
            // is. In Release it does not: this is a performance rule, not a data-safety one, and a
            // mail bug must not crash the app its owner uses every day. (The stores' guard, which
            // can reach the journal, records its violations; this file stands alone and cannot.)
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            preconditionFailure("mail's file work is not for the main thread (invariant 10)")
            #endif
        })
}

/// How much a file installed through `MailFiles` is made to survive a power cut.
///
/// A rename is atomic — a reader sees the whole old file or the whole new one — but atomic is
/// not durable: nothing says the file's bytes are on the disk when the rename is, and after a
/// crash the file can be at its final name, the right length, and empty.
enum MailFileDurability: Sendable {
    /// Atomic only: the disposable tier (`Cache/`: an attachment that can be fetched again, a
    /// picture, the first-frame file, which must tolerate being cut short in any case). No sync
    /// is made, so this costs what it always did.
    case atomic
    /// The temporary file is synced before the move, and the directory after it, so a crash
    /// leaves the whole file at its final name or no file at all. For the precious tier —
    /// **everything under `Intent/Attachments`**: a draft's attachment is named by a row that
    /// `intent.sqlite` has committed with a full fsync, and a row that names a file the disk
    /// does not hold is a message that goes out with an empty attachment and nothing to say so.
    case synced
}

/// The one door for every file mail creates outside SQLite (MAIL-ENGINE 11.2): an attachment, a
/// remote picture, the first-frame file, a draft's attachment, an upload body.
///
/// A file arrives by being **written to a temporary file, then moved into place atomically,
/// then given its protection class**, and — on the Mac, for a file from a stranger — its
/// quarantine; and, for a file that must survive a power cut, synced (`MailFileDurability`).
/// Each step is here so that no later package can leave one out: the static test of 10.4 refuses
/// `copyItem(`, `moveItem(`, `createFile(` and `.write(to:` in every other mail file, so a path
/// that wrote a file without them would not get past it.
///
/// Why the order is what it is:
///
/// - **The temporary file sits beside its destination**, in the same directory, under a hidden
///   name (`temporaryPrefix`, `temporarySuffix`), so the move is a rename on one volume: a
///   reader sees the old file or the whole new one, never a half-written one.
/// - **Quarantine goes on the temporary file, before the move**, so the file is quarantined from
///   the moment it has its final name — "before anything can reach it" (11.2). An extended
///   attribute travels with a rename.
/// - **A synced file is synced before the move and its directory after it**, so that the bytes
///   are on the disk before the name is, and the name is on the disk before this returns.
/// - **The protection class goes on after the move**, never before (`MailFileAttributes`).
///
/// A file that cannot be given what it was asked for is not left behind: if the quarantine or
/// the sync cannot be done the temporary file is deleted and nothing is installed; if the class
/// cannot be set after the move, or the directory cannot be synced, the installed file is
/// removed again. An attachment without its quarantine, or a `.complete` file that is not, is a
/// worse thing to have than none. **That includes the file it replaced:** when the destination
/// existed, a failure after the move leaves neither the new file nor the old one, so do not
/// install over a file that matters and expect to keep it if this throws.
///
/// A crash between creating a temporary file and moving it leaves it where it is. Nothing here
/// sweeps them: `isTemporaryName` says what one is called, for the disk-usage walk and eviction
/// that will.
///
/// Everything here is for a background thread (`MailFileAttributes.requireOffMain`).
enum MailFiles {

    /// What a temporary file's name starts and ends with.
    static let temporaryPrefix = ".mail-"
    static let temporarySuffix = ".partial"

    /// Whether `name` is a temporary file's: one left behind by a crash may be deleted.
    static func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix)
    }

    /// A path for a temporary file beside `destination`, under a hidden name that has not been
    /// used. Nothing is created.
    static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString)\(temporarySuffix)", isDirectory: false)
    }

    /// Creates an empty temporary file beside `destination` and returns its path, for a caller
    /// that streams into it (a `FileHandle(forWritingTo:)`) and then calls `install`. No
    /// protection class is set on it: that comes after the move.
    static func createTemporary(beside destination: URL,
                                attributes: MailFileAttributes = .live) throws -> URL {
        attributes.requireOffMain()
        let url = temporaryURL(beside: destination)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw MailFileError.failed(.create, code: Int(errno)) }
        close(descriptor)
        return url
    }

    /// Moves a finished temporary file into place and gives it its protection class and, if
    /// asked, its quarantine. The temporary file must be on the destination's volume (make it
    /// with `createTemporary(beside:)`) and its writer finished with it. An existing file at
    /// `destination` is replaced in one step. Throws `MailFileError` and, when it does, leaves no
    /// temporary file behind.
    ///
    /// `durability` says whether it is made to survive a power cut, and `quarantine` whether it
    /// is marked as having come from outside, on the Mac. **Neither has a default**, because
    /// forgetting either is the fault they exist for and nothing would show it: every caller
    /// says which tier its file is. A file under `Intent/` is installed `.synced`; one in
    /// `Cache/` is `.atomic`, which costs what it always did. A stored attachment is
    /// quarantined; a file mail made itself (`first-page.json`) is `nil`, written out.
    static func install(temporary: URL,
                        at destination: URL,
                        protection: FileProtectionType,
                        quarantine: MailQuarantine?,
                        durability: MailFileDurability,
                        attributes: MailFileAttributes = .live) throws {
        attributes.requireOffMain()

        do {
            if let quarantine { try attributes.quarantine(temporary, quarantine) }
            if durability == .synced { try attributes.synchronize(temporary) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        // rename(2): atomic, and replaces what is at the destination.
        if rename(temporary.path, destination.path) != 0 {
            let code = Int(errno)
            try? FileManager.default.removeItem(at: temporary)
            throw MailFileError.failed(.move, code: code)
        }

        do {
            // The name is on the disk before this returns, as the bytes were before the name.
            if durability == .synced { try attributes.synchronize(destination.deletingLastPathComponent()) }
            try attributes.protect(destination, protection)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Writes `data` to a temporary file beside `destination` and installs it. The way
    /// `first-page.json` and any other file held whole in memory is made.
    static func install(_ data: Data,
                        at destination: URL,
                        protection: FileProtectionType,
                        quarantine: MailQuarantine?,
                        durability: MailFileDurability,
                        attributes: MailFileAttributes = .live) throws {
        attributes.requireOffMain()
        let temporary = temporaryURL(beside: destination)
        do {
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw MailFileError.failed(.create, code: (error as NSError).code)
        }
        try install(temporary: temporary, at: destination, protection: protection,
                    quarantine: quarantine, durability: durability, attributes: attributes)
    }
}

#endif
