import XCTest

/// The mail renderer's regression gate (docs/design/PROBLEM-REPORTS.md): every case in
/// `tools/reports/mail-cases/` (synthetic, public) and, on a machine that has it, in the git-ignored
/// `private/mail-render-corpus/` (real mail pulled from reports, never in the tree) goes through
/// `MailHTMLPreparer`. A case is `input.html` and, once its fix is known, `expect.json`:
/// `contains` / `absent` (text that must or must not be shown) and `blocksAtMost`. A case
/// without one only has to prepare. What each case drew is written to
/// `.build/mail-render-out/<case>.txt` to read beside it.
final class MailRenderCorpusTests: XCTestCase {
    private struct Expect: Decodable {
        var contains: [String]?
        var absent: [String]?
        var blocksAtMost: Int?
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func cases(in folder: URL) -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return found.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("input.html").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testSyntheticCases() throws {
        let found = cases(in: Self.root.appendingPathComponent("tools/reports/mail-cases"))
        XCTAssertFalse(found.isEmpty, "the public cases are part of the tree")
        for folder in found { try check(folder) }
    }

    func testPrivateCorpusWhenPresent() throws {
        let found = cases(in: Self.root.appendingPathComponent("private/mail-render-corpus"))
        try XCTSkipIf(found.isEmpty, "no private corpus on this machine")
        for folder in found { try check(folder) }
    }

    private func check(_ folder: URL) throws {
        let name = folder.lastPathComponent
        let html = try String(contentsOf: folder.appendingPathComponent("input.html"), encoding: .utf8)
        let plain = try? String(contentsOf: folder.appendingPathComponent("input.txt"), encoding: .utf8)
        let prepared: MailPreparedBody
        do { prepared = try MailHTMLPreparer.prepare(plain: plain, html: html) }
        catch { return XCTFail("\(name): couldn't prepare (\(error))") }
        let blocks = prepared.text.blocks.map { $0.runs.map(\.text).joined() }
        let shown = blocks.joined(separator: "\n")
        let out = Self.root.appendingPathComponent(".build/mail-render-out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? shown.write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)

        guard let data = try? Data(contentsOf: folder.appendingPathComponent("expect.json")) else { return }
        let expect = try JSONDecoder().decode(Expect.self, from: data)
        for text in expect.contains ?? [] { XCTAssertTrue(shown.contains(text), "\(name): shows \(text.debugDescription)") }
        for text in expect.absent ?? [] { XCTAssertFalse(shown.contains(text), "\(name): hides \(text.debugDescription)") }
        if let most = expect.blocksAtMost { XCTAssertLessThanOrEqual(blocks.count, most, "\(name): at most \(most) blocks") }
    }
}
