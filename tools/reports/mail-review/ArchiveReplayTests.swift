import Foundation
import XCTest

/// Opt-in standalone replay. Private inputs and rendered outputs stay in the caller's local folder.
final class ArchiveReplayTests: XCTestCase {
    private struct Observation: Encodable {
        let name: String
        let version: Int
        let formatted: Bool
        let blocks: Int
        let samplesMilliseconds: [Double]
    }

    func testReplay() throws {
        let env = ProcessInfo.processInfo.environment
        let inputDirectories = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(env["MAIL_ARCHIVE_INPUTS"]).utf8))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["MAIL_ARCHIVE_OUTPUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var observations: [Observation] = []
        for directory in inputDirectories {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let cases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for folder in cases {
                let file = folder.appendingPathComponent("input.html")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let key = folder.lastPathComponent
                let html = try String(contentsOf: file, encoding: .utf8)
                let plain = try? String(contentsOf: folder.appendingPathComponent("input.txt"), encoding: .utf8)
                let prepared = try MailHTMLPreparer.prepare(plain: plain, html: html)
                let times = try (0..<5).map { _ in
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try MailHTMLPreparer.prepare(plain: plain, html: html)
                    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }
                let snapshot = try MailOriginalDocument.prepare(html)
                try MailOriginalDocument.page(snapshot, embedded: true)
                    .write(to: output.appendingPathComponent("\(key)-formatted.html"), atomically: true, encoding: .utf8)
                try encoder.encode(prepared).write(to: output.appendingPathComponent("\(key)-native.json"), options: .atomic)
                observations.append(Observation(name: key, version: prepared.version, formatted: prepared.prefersOriginal == true,
                                                blocks: prepared.text.blocks.count, samplesMilliseconds: times))
            }
        }
        XCTAssertFalse(observations.isEmpty)
        try encoder.encode(observations).write(to: output.appendingPathComponent("observations.json"), options: .atomic)
    }
}
