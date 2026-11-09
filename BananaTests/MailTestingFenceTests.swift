import XCTest

/// Everything under `Banana/Model/Mail/Testing/` is compiled into the app, on purpose, and fenced
/// (MAIL-ENGINE 17.5, L10).
///
/// The folder is inside the one the four app targets take whole, and it has to be: the fixtures
/// drive routes inside the app as well as the tests. So **every file there is wholly inside
/// `#if DEBUG || MAIL_FIXTURES` … `#endif`**, alone or inside conditions that each hold the whole
/// file (the email build gate every mail source carries). A Debug build has
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
        let root = SourceTree.root
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
    ///
    /// The fence may sit inside other conditions that each hold the whole file, such as the
    /// email build gate (`#if !BANANA_PUBLIC`) every mail source carries. Nested conditions all
    /// have to hold for a line to compile, so a whole-file wrapper only ever narrows the builds
    /// that have the file; it can never put a fixture where the fence alone would not. A wrapper
    /// with an `#else`, or one that closes before the end, does not hold the whole file and is
    /// refused like a fence that does that.
    private func fenceProblems(in source: String) -> [String] {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var offset = 0  // lines peeled off the top, for the line numbers a problem names
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        while true {
            // A trailing newline, and the blank line between two closing `#endif`s, are allowed.
            while let last = lines.last, isBlank(last) { lines.removeLast() }
            guard let first = lines.first, first.hasPrefix("#if") else {
                return ["the first line is not `\(Self.fence)`"]
            }
            guard lines.last == "#endif" else { return ["the last line is not `#endif`"] }
            // The first line's condition must close on the last line and nowhere before it, with
            // no other branch at its level.
            var depth = 0
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") { depth += 1 }
                else if trimmed.hasPrefix("#endif") { depth -= 1 }
                else if trimmed.hasPrefix("#else") && depth == 1 {
                    return ["`\(first)` has another branch on line \(offset + index + 1)"]
                }
                if depth < 0 { return ["an `#endif` with no `#if` on line \(offset + index + 1)"] }
                if depth == 0 && index < lines.count - 1 {
                    return ["the fence closes on line \(offset + index + 1), before the end"]
                }
            }
            if depth != 0 { return ["an `#if` is never closed"] }
            if first == Self.fence { return [] }
            // A wrapper around the whole file: look for the fence inside it.
            lines = Array(lines.dropFirst().dropLast())
            offset += 1
            while let top = lines.first, isBlank(top) { lines.removeFirst(); offset += 1 }
        }
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
        XCTAssertEqual(fenceProblems(in: "#if !BANANA_PUBLIC\n\(Self.fence)\nenum A {}\n#endif\n\n#endif\n"), [],
                       "a condition around the whole file only narrows it")
        XCTAssertFalse(fenceProblems(in: "#if !BANANA_PUBLIC\n\(Self.fence)\nenum A {}\n#endif\nenum Shipped {}\n#endif\n").isEmpty,
                       "a declaration inside the wrapper but after the fence is in the shipped app")
        XCTAssertFalse(fenceProblems(in: "#if !BANANA_PUBLIC\nenum Shipped {}\n#else\n\(Self.fence)\nenum A {}\n#endif\n#endif\n").isEmpty,
                       "a wrapper with another branch does not hold the whole file")
        XCTAssertFalse(fenceProblems(in: "#if !BANANA_PUBLIC\nenum Shipped {}\n#endif\n").isEmpty,
                       "a wrapper is not a fence")
        XCTAssertFalse(fenceProblems(in: "\(Self.fence)\nenum A {}\n#else\nenum Shipped {}\n#endif\n").isEmpty,
                       "the fence's own #else is outside it")
    }

    /// In this build, which defines DEBUG, what the fence holds is there: the fixtures this
    /// package wrote are reachable, and the registry names them. (That they are *not* there in a
    /// Release build of a production target is the Release build compiling without them.)
    func testInADebugBuildTheFencedFixturesAreThere() {
        XCTAssertFalse(MailHostileMessages.senderAndHeaderSet.isEmpty)
        XCTAssertFalse(MailSlices.hostileMessageSets.isEmpty)
    }
}
