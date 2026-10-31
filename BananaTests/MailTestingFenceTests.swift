import XCTest

/// Everything under `Banana/Model/Mail/Testing/` is compiled into the app, on purpose, and fenced
/// (MAIL-ENGINE 17.5, L10).
///
/// The folder is inside the one the four app targets take whole, and it has to be: the fixtures
/// drive routes inside the app as well as the tests. So **every file there is wholly inside
/// `#if DEBUG || MAIL_FIXTURES` … `#endif`, its first line and its last.** A Debug build has
/// them; a Release build of the two production targets, which defines neither, compiles each of
/// those files to nothing; and the two Beta targets' Release configuration defines
/// `MAIL_FIXTURES` (P24), which is how the owner's device runs have the fixture mailbox. A file
/// there without the fence would put hostile HTML and a pretend mailbox in the shipped app and
/// nothing would say so; this is what says so.
///
/// Like `MailSourceTreeTests`, it reads the checkout the tests were built from and skips where
/// that is not there. The fence's *effect* in a Release build is the Release build itself, which
/// must compile: `MailSlices` names a fixture type only inside the same condition.
final class MailTestingFenceTests: XCTestCase {

    private static let fence = "#if DEBUG || MAIL_FIXTURES"

    private func testingFolder() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let contract = root.appendingPathComponent("Banana/Model/Mail/MailContract.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: contract.path),
                          "the source tree is not on this machine")
        return root.appendingPathComponent("Banana/Model/Mail/Testing")
    }

    private func swiftFiles(under folder: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        var files: [URL] = []
        for case let file as URL in enumerator
        where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.append(file)
        }
        return files
    }

    /// What is wrong with the fence of `source`, if anything: not wholly inside one
    /// `#if DEBUG || MAIL_FIXTURES` and its `#endif`.
    private func fenceProblems(in source: String) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var problems: [String] = []
        guard let first = lines.first, first == Self.fence else {
            return ["the first line is not `\(Self.fence)`"]
        }
        // The last non-empty line, with a trailing newline allowed.
        guard let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[lastIndex] == "#endif" else {
            return ["the last line is not `#endif`"]
        }
        // The fence must not close before the end: depth 1 on every line between.
        var depth = 0
        for (index, line) in lines.enumerated() where index <= lastIndex {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") { depth += 1 }
            if trimmed.hasPrefix("#endif") { depth -= 1 }
            if depth == 0 && index < lastIndex { problems.append("the fence closes on line \(index + 1), before the end") }
            if depth < 0 { problems.append("an `#endif` with no `#if` on line \(index + 1)") }
        }
        if depth != 0 { problems.append("an `#if` is never closed") }
        return problems
    }

    // MARK: - The folder

    func testEverySwiftFileUnderTestingIsWhollyInsideTheFence() throws {
        let files = try swiftFiles(under: testingFolder())
        XCTAssertFalse(files.isEmpty, "there is a folder to check")
        for file in files {
            XCTAssertEqual(file.pathExtension, "swift", "\(file.lastPathComponent): only Swift files live under M/")
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(fenceProblems(in: source), [], file.lastPathComponent)
        }
    }

    /// The fixtures are not written with a character that cannot be seen or that looks like
    /// another. Each is an escape, so that a diff and an editor show what is there and the
    /// lines around it are not drawn backwards.
    func testNoFileUnderTestingHoldsAnInvisibleOrLookAlikeCharacterWrittenAsItself() throws {
        for file in try swiftFiles(under: testingFolder()) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            var line = 1
            for scalar in source.unicodeScalars {
                if scalar == "\n" { line += 1 }
                let value = scalar.value
                let raw = scalar.properties.isDefaultIgnorableCodePoint
                    || MailHiddenCharacters.isDirectionControl(scalar)
                    || (0x0370...0x03FF).contains(value) || (0x0400...0x052F).contains(value)   // Greek, Cyrillic
                    || (0xFE50...0xFE6F).contains(value) || (0xFF00...0xFFEF).contains(value)    // small and full-width forms
                XCTAssertFalse(raw, "\(file.lastPathComponent):\(line) holds U+\(String(value, radix: 16, uppercase: true)) as itself")
            }
        }
    }

    /// The same check applied to this package's own sources: the mail folder holds no raw direction
    /// override, which would draw the rest of its line backwards in an editor and a diff.
    func testNoSourceFileOfMailHoldsADirectionControlWrittenAsItself() throws {
        let folder = try testingFolder().deletingLastPathComponent()
        for file in try swiftFiles(under: folder) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.unicodeScalars.contains(where: MailHiddenCharacters.isDirectionControl),
                           "\(file.lastPathComponent) holds a direction control as itself")
        }
    }

    // MARK: - The check itself can fail

    func testTheFenceCheckCatchesWhatItIsForTheFileWithNoFenceAndTheFenceThatClosesEarly() {
        let good = "\(Self.fence)\nimport Foundation\nenum A {}\n#endif\n"
        XCTAssertEqual(fenceProblems(in: good), [])

        XCTAssertFalse(fenceProblems(in: "import Foundation\nenum A {}\n").isEmpty, "no fence at all")
        XCTAssertFalse(fenceProblems(in: "\(Self.fence)\nenum A {}\n").isEmpty, "never closed")
        XCTAssertFalse(fenceProblems(in: "#if DEBUG\nenum A {}\n#endif\n").isEmpty, "the wrong condition")
        XCTAssertFalse(fenceProblems(in: "\(Self.fence)\nenum A {}\n#endif\nenum Shipped {}\n").isEmpty,
                       "a declaration after the fence is in the shipped app")
        XCTAssertFalse(fenceProblems(in: "\(Self.fence)\nenum A {}\n#endif\n#if DEBUG\nenum B {}\n#endif\n").isEmpty,
                       "two fences are not one")
        XCTAssertFalse(fenceProblems(in: "// a header comment\n\(Self.fence)\nenum A {}\n#endif\n").isEmpty,
                       "a line before the fence is outside it")
        XCTAssertEqual(fenceProblems(in: "\(Self.fence)\n#if os(macOS)\nenum A {}\n#endif\n#endif\n"), [],
                       "an inner #if is fine")
    }

    /// In this build, which defines DEBUG, what the fence holds is there: the fixtures this
    /// package wrote are reachable, and the registry names them. (That they are *not* there in a
    /// Release build of a production target is the Release build compiling without them.)
    func testInADebugBuildTheFencedFixturesAreThere() {
        XCTAssertFalse(MailHostileMessages.senderAndHeaderSet.isEmpty)
        XCTAssertFalse(MailSlices.hostileMessageSets.isEmpty)
    }
}
