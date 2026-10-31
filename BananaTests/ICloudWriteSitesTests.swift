import XCTest

/// With every tier read-only, nothing writes iCloud but the two kept key-value keys
/// (docs/design/DATA-PLATFORM.md §8 step 2): every place in the app that could write it is listed
/// in `tools/icloud-write-sites.tsv` with the gate it sits behind, and a new one fails here until
/// it's reviewed and listed.
///
/// What counts as a place that writes iCloud:
/// - CloudKit: `sendChanges`, `state.add(pending…)`, `modifyRecords`/`modifyRecordZones`/
///   `modifySubscriptions`, `CKModify…Operation`, a database's `save` or `delete…(withID:)`;
/// - the key-value store: `set`/`removeObject` on `NSUbiquitousKeyValueStore` itself (everything
///   else goes through `LegacyKVS`, whose own two writes are listed), and only the files in
///   `rawKeyValueFiles` may name the store;
/// - iCloud Drive: file writes, removals, copies and moves in the code that holds a ubiquity
///   container's URL (`ubiquityScopes`); any other file naming `forUbiquityContainerIdentifier`
///   fails.
///
/// Kinds in the list:
/// - `gated`: checked here: a write gate (`mayWrite(`, `writes`, `anyWrites`, `…Write`) comes
///   between the enclosing declaration and the call;
/// - `kept`: a write of one of the two kept keys (`LegacyKVS.keptKeys`);
/// - `purge`: `ICloudPurge`, which deletes only behind its gate, never while a tier writes;
/// - `local`: a local file written by code that also holds a ubiquity URL.
final class ICloudWriteSitesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let directories = ["Banana", "Shared", "BananaMac", "BananaWatch", "BananaWidget", "BananaWatchWidget"]
    private static let listURL = root.appendingPathComponent("tools/icloud-write-sites.tsv")

    private static let cloudKit = regex(#"sendChanges\(|state\.add\(pending|modifyRecords\(|modifyRecordZones\(|modifySubscriptions\(|CKModify\w*Operation|[Dd]atabase\.save\(|deleteRecord\(withID|deleteRecordZone\(withID|deleteSubscription\(withID"#)
    private static let fileWrite = regex(#"\.write\(to:|removeItem\(|createDirectory\(|copyItem\(|moveItem\(|replaceItem|setUbiquitous\(|coordinate\(writingItemAt"#)
    private static let gate = regex(#"mayWrite\(|\bwrites\b|anyWrites\b|[a-z]Write\b"#)
    private static let declaration = regex(#"\bfunc\s|(?<![.\w])init\(|\bvar\s+\w+\s*:\s*[^=]+\{\s*$"#)

    /// Code that holds a ubiquity container's URL: the whole file (nil), or the block opened by
    /// this line and closed by the next `}` at the start of a line.
    private static let ubiquityScopes: [String: String?] = [
        "Banana/Model/CloudBackup.swift": nil,
        "Banana/Model/Transcript.swift": "private enum TranscriptCloudFiles {",
        "Banana/Model/VoiceNoteStore.swift": "private enum VoiceNoteCloudFiles {",
        "Banana/Model/Sync/ICloudPurge+Live.swift": nil,
    ]
    /// Files that may name `NSUbiquitousKeyValueStore`, and the name they hold it by (nil: only
    /// its notification, nothing written).
    private static let rawKeyValueFiles: [String: String?] = [
        "Banana/Model/Sync/LegacyCloud.swift": "store",
        "Banana/Model/GoogleCalendarService.swift": "cloud",
        "Banana/Model/DownloadManager.swift": "store",
        "Banana/Model/TaskDurationStore.swift": nil,
        "Banana/Model/Sync/ICloudPurge+Live.swift": nil,
        "Banana/Model/Sync/ICloudPurge.swift": "keyValues",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A line's code: nothing for a comment line.
    private static func code(_ line: Substring) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("//") || text.hasPrefix("*") ? "" : text
    }

    struct Site: Hashable { let path: String; let code: String }
    struct Found { let site: Site; let line: Int; let gated: Bool }

    private func swiftFiles() -> [String] {
        var paths: [String] = []
        for directory in Self.directories {
            let base = Self.root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                paths.append(String(url.standardizedFileURL.path.dropFirst(Self.root.standardizedFileURL.path.count + 1)))
            }
        }
        return paths.sorted()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func scan() throws -> [Found] {
        var found: [Found] = []
        for path in swiftFiles() {
            let lines = try text(path).split(separator: "\n", omittingEmptySubsequences: false)
            var inScope = Array(repeating: false, count: lines.count)
            if let scope = Self.ubiquityScopes[path] {
                if let opener = scope {
                    var open = false
                    for (index, line) in lines.enumerated() {
                        if line.hasPrefix(opener) { open = true }
                        inScope[index] = open
                        if open, line == "}" { open = false }
                    }
                } else {
                    inScope = Array(repeating: true, count: lines.count)
                }
            }
            let receiver = Self.rawKeyValueFiles[path].flatMap { $0 }.map { Self.regex(#"\b\#($0)\.(set|removeObject)\("#) }
            for (index, line) in lines.enumerated() {
                let code = Self.code(line)
                guard !code.isEmpty else { continue }
                let isSite = Self.matches(Self.cloudKit, code) || (inScope[index] && Self.matches(Self.fileWrite, code))
                    || (receiver.map { Self.matches($0, code) } ?? false)
                guard isSite else { continue }
                var start = index
                while start > 0, !Self.matches(Self.declaration, Self.code(lines[start])) { start -= 1 }
                let gated = (start...index).contains { Self.matches(Self.gate, Self.code(lines[$0])) }
                found.append(Found(site: Site(path: path, code: code), line: index + 1, gated: gated))
            }
        }
        return found
    }

    struct Entry { let kind: String; let site: Site; let why: String }

    private func allowList() throws -> [Entry] {
        try String(contentsOf: Self.listURL, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 4, "kind, path, code, why: \(line)")
            guard fields.count == 4 else { return nil }
            return Entry(kind: fields[0], site: Site(path: fields[1], code: fields[2]), why: fields[3])
        }
    }

    func testEveryICloudWriteIsListedWithItsGate() throws {
        let found = try scan()
        let entries = try allowList()
        XCTAssertFalse(found.isEmpty, "the scan found nothing: is the repository at \(Self.root.path)?")

        var listed: [Site: Int] = [:]
        for entry in entries { listed[entry.site, default: 0] += 1 }
        var seen: [Site: Int] = [:]
        for item in found { seen[item.site, default: 0] += 1 }
        let unlisted = found.filter { (seen[$0.site] ?? 0) > (listed[$0.site] ?? 0) }
        XCTAssert(unlisted.isEmpty, """
            iCloud writes not in tools/icloud-write-sites.tsv: review each (it must not write with every \
            tier read-only), then list it (kind, path, code, why):
            \(unlisted.map { "?\t\($0.site.path)\t\($0.site.code)\t(line \($0.line))" }.joined(separator: "\n"))
            """)
        let stale = Set(entries.map(\.site)).filter { (listed[$0] ?? 0) > (seen[$0] ?? 0) }
        XCTAssert(stale.isEmpty, "listed but no longer in the code (remove them): \(stale.map { "\($0.path): \($0.code)" })")

        let keptNames = ["accountHintKey", "tokenKey"]
        for entry in entries {
            XCTAssertFalse(entry.why.trimmingCharacters(in: .whitespaces).isEmpty, "no reason given: \(entry.site)")
            switch entry.kind {
            case "gated":
                for item in found where item.site == entry.site {
                    XCTAssert(item.gated, "\(item.site.path):\(item.line) has no write gate in its declaration: \(item.site.code)")
                }
            case "kept":
                XCTAssert(keptNames.contains { entry.site.code.contains($0) }, "not a kept key: \(entry.site)")
            case "purge":
                XCTAssert(entry.site.path.hasPrefix("Banana/Model/Sync/ICloudPurge"), "only the purge deletes ungated: \(entry.site)")
            case "local":
                break
            default:
                XCTFail("unknown kind \(entry.kind): \(entry.site)")
            }
        }
    }

    /// The kept keys' writers write only those keys.
    func testTheKeptKeysAreTheOnesWrittenRaw() throws {
        XCTAssert(try text("Banana/Model/GoogleCalendarService.swift").contains(#"accountHintKey = "googleCalendar.accountHint.v1""#))
        XCTAssert(try text("Banana/Model/DownloadManager.swift").contains(#"tokenKey = "podcastPeerGroupToken.v1""#))
    }

    /// No other code holds the key-value store or a ubiquity container directly.
    func testOnlyKnownFilesReachICloudDirectly() throws {
        for path in swiftFiles() {
            let source = try text(path)
            if source.contains("NSUbiquitousKeyValueStore") {
                XCTAssertNotNil(Self.rawKeyValueFiles[path], "\(path) uses NSUbiquitousKeyValueStore: go through LegacyKVS, or list it here")
            }
            if source.contains("forUbiquityContainerIdentifier") {
                XCTAssertNotNil(Self.ubiquityScopes[path], "\(path) opens a ubiquity container: add its code to ubiquityScopes and list its writes")
            }
        }
    }
}
