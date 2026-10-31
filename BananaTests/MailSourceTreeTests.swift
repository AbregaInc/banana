import XCTest

/// Rules about mail's source files that the compiler does not enforce, checked by reading the
/// files themselves.
///
/// Two of mail's folders are handed to Xcode as whole directories rather than file by file
/// (`project.yml`), so that adding a file to mail never means editing the project. The price
/// is that a directory entry takes whatever is in the directory: a `.json` fixture or a note
/// left beside the Swift files would be copied into all four apps as a resource and shipped,
/// and nothing would say so. The first test below is what says so.
///
/// The others hold the contract file to the rules written at its top, and hold the probe that
/// finds unbuilt members to the protocol it probes.
///
/// These tests read the checkout the tests were built from, found from this file's own path.
/// On a device, where that checkout is not there, they skip.
final class MailSourceTreeTests: XCTestCase {

    /// The directories given to Xcode whole. Relative to the repository's root.
    private static let wholeDirectories = ["Banana/Model/Mail", "Banana/Model/MailUI/Pure"]

    private func repositoryRoot() throws -> URL {
        // BananaTests/<this file> — the root is two levels up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let contract = root.appendingPathComponent("Banana/Model/Mail/MailContract.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: contract.path),
                          "the source tree is not on this machine")
        return root
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: try repositoryRoot().appendingPathComponent(path), encoding: .utf8)
    }

    func testTheDirectoriesXcodeTakesWholeHoldOnlySwiftFiles() throws {
        let root = try repositoryRoot()
        for directory in Self.wholeDirectories {
            let folder = root.appendingPathComponent(directory)
            let files = try XCTUnwrap(FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
            var swiftFiles = 0
            for case let file as URL in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else { continue }
                XCTAssertEqual(file.pathExtension, "swift",
                               "\(file.lastPathComponent) in \(directory) would ship inside the app")
                swiftFiles += 1
            }
            // A directory entry with no Swift file in it is not a source of anything.
            XCTAssertGreaterThan(swiftFiles, 0, directory)
        }
    }

    func testTheContractFileImportsFoundationAndCombineAndNothingElse() throws {
        let imports = try source("Banana/Model/Mail/MailContract.swift")
            .split(separator: "\n")
            .filter { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ") }
        XCTAssertEqual(imports, ["import Foundation", "import Combine"])
    }

    func testTheIdentifierFilesImportOnlyFoundation() throws {
        // They are compiled a second time, into the UI tests, which have nothing else of the
        // app's. One that named a view or a model would stop the UI tests building.
        let folder = try repositoryRoot().appendingPathComponent("Banana/Model/MailUI/Pure")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("MailIdentifiers") && $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("MailIdentifiers.swift"))
        for file in files {
            let imports = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n")
                .filter { $0.hasPrefix("import ") }
            XCTAssertEqual(imports, ["import Foundation"], file)
        }
    }

    func testTheProbeNamesEveryRequirementOfTheProtocol() throws {
        // The probe is a list written by hand. A requirement added to the protocol compiles
        // without it — its default sees to that — so the count is taken from the source: one
        // more requirement there than names here, and this fails until the probe has grown.
        let contract = try source("Banana/Model/Mail/MailContract.swift")
        let start = try XCTUnwrap(contract.range(of: "@MainActor protocol MailSource: AnyObject {"))
        let rest = start.upperBound..<contract.endIndex
        let end = try XCTUnwrap(contract.range(of: "\n}\n", range: rest))
        let requirements = contract[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.hasPrefix("func ") || line.hasPrefix("@discardableResult func ")
                    || line.hasPrefix("var ")
            }
        XCTAssertEqual(requirements.count, 59, "the protocol's requirements, counted in its source")
        XCTAssertEqual(requirements.count, MailSourceProbe.everyMember.count)
    }
}
