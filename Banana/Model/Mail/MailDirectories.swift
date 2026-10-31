#if !BANANA_PUBLIC
import Foundation

/// Where mail keeps its files, and the promise that the directories exist, are kept out of
/// backup, and have their protection class **before any store is opened** (MAIL-ENGINE 4.1).
///
/// ```
/// <root>/                          BananaMail/ in the app; a temporary folder in a test
/// ├── Intent/                      precious: what was done and written, not yet in Gmail
/// │   ├── intent.sqlite
/// │   └── Attachments/             files attached to unsent messages
/// └── Cache/                       disposable: may be deleted whole at any time
///     ├── index.sqlite
///     ├── search.sqlite
///     ├── blobs.sqlite
///     ├── Attachments.noindex/
///     ├── Remote.noindex/
///     └── first-page.json
/// ```
///
/// **Making a `MailDirectories` is what prepares the tree**, which is how "set before any store
/// is opened" is kept: a store opens from a `MailDirectories` value, and a value exists only
/// once every directory is made and has its class. SQLite creates `-wal` and `-shm` on the first
/// write, and a new file takes the class of the directory it is created in, so a class set on
/// the directory afterwards would leave the log files with the default.
///
/// - The four databases and `Intent/Attachments` are `completeUntilFirstUserAuthentication`: a
///   background refresh must read and write them with the phone locked.
/// - `Attachments.noindex` and `Remote.noindex` are `complete`: unreadable while locked, and
///   the engine treats them as absent then. (`first-page.json` is a file in `Cache/`, which holds
///   the databases, so its class is set on the file by `MailFiles` after it is written.)
/// - `Intent/` and `Cache/` are excluded from backup. Excluding the cache is the brief;
///   excluding intent is a choice: a device restored from last week's backup would otherwise
///   replay last week's "archive this" over whatever was done since.
///
/// It is cheap and safe to make again at every launch: it creates what is missing and sets the
/// same attributes on what is there.
struct MailDirectories: Sendable {

    /// The folder everything is under.
    let root: URL

    var intent: URL { root.appendingPathComponent("Intent", isDirectory: true) }
    var intentAttachments: URL { intent.appendingPathComponent("Attachments", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    var attachments: URL { cache.appendingPathComponent("Attachments.noindex", isDirectory: true) }
    var remote: URL { cache.appendingPathComponent("Remote.noindex", isDirectory: true) }

    var intentDatabase: URL { intent.appendingPathComponent("intent.sqlite") }
    var indexDatabase: URL { cache.appendingPathComponent("index.sqlite") }
    var searchDatabase: URL { cache.appendingPathComponent("search.sqlite") }
    var blobsDatabase: URL { cache.appendingPathComponent("blobs.sqlite") }
    var firstPage: URL { Self.firstPage(under: root) }

    /// Where `first-page.json` is, for a tree under `root` — **path arithmetic and nothing else**: no
    /// directory is made, no attribute set, no store touched, no file looked at, and so it may be
    /// called on the main thread. 4.11 has the first frame read that one small file there, before
    /// anything else of mail's has started, and making a `MailDirectories` is file work that traps
    /// on the main thread; this is the way to the file's path that does not.
    static func firstPage(under root: URL) -> URL {
        root.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("first-page.json")
    }

    /// Creates the tree under `root` if it is not there, and sets each directory's protection
    /// class and backup exclusion. Throws `MailFileError` if any of that fails. File work: not for
    /// the main thread.
    init(root: URL, attributes: MailFileAttributes = .live) throws {
        attributes.requireOffMain()
        self.root = root

        let untilFirstUnlock = FileProtectionType.completeUntilFirstUserAuthentication
        let whenUnlocked = FileProtectionType.complete
        let plan: [(url: URL, protection: FileProtectionType, excludeFromBackup: Bool)] = [
            (root, untilFirstUnlock, false),
            (intent, untilFirstUnlock, true),
            (intentAttachments, untilFirstUnlock, false),
            (cache, untilFirstUnlock, true),
            (attachments, whenUnlocked, false),
            (remote, whenUnlocked, false),
        ]
        for step in plan {
            do {
                try FileManager.default.createDirectory(at: step.url, withIntermediateDirectories: true)
            } catch {
                throw MailFileError.failed(.directory, code: (error as NSError).code)
            }
            try attributes.protect(step.url, step.protection)
            if step.excludeFromBackup { try attributes.excludeFromBackup(step.url) }
        }
    }
}

#endif
