import CryptoKit
import XCTest

/// Banana Pi's Mac model files: the pin the app ships, and the checks that decide whether the
/// files on disk can be run or must be fetched again.
final class PinnedModelFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func manifest(_ files: [String: Data], revision: String = "0123456789abcdef") throws -> PinnedModelFiles.Manifest {
        let entries = files.mapValues { data in
            ["bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()] as [String: Any]
        }
        let json: [String: Any] = [
            "repo": "org/Tiny-Model", "revision": revision, "files": entries,
            "profile": ["modelId": "tiny", "serverModel": "locals/tiny", "name": "Tiny", "port": 41789,
                        "contextWindow": 4096, "maxTokens": 256, "thinkingLevel": "off"],
        ]
        return try JSONDecoder().decode(PinnedModelFiles.Manifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTheShippedPinDecodesWithEveryFileHashedAndAServingProfile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Banana/Pi/Resources/pi-local-model.json").standardized
        let pin = try JSONDecoder().decode(PinnedModelFiles.Manifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(pin.revision.count, 40, "a full commit, never a branch")
        XCTAssertNotNil(pin.files["model.safetensors"])
        XCTAssertTrue(pin.files.values.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 })
        XCTAssertEqual(pin.profile.serverModel.split(separator: "/").first, "locals")
        // Locals names a local-path model from that folder's lowercased basename, including
        // the revision suffix. A developer alias is not advertised by the bundled worker.
        XCTAssertEqual(pin.profile.serverModel, "locals/" + PinnedModelFiles.folder(for: pin).lastPathComponent.lowercased())
        XCTAssertLessThan(pin.profile.maxTokens, pin.profile.contextWindow)
    }

    func testTheFolderIsNamedByRevisionSoANewPinNeverOverwritesTheOld() throws {
        let base = URL(fileURLWithPath: "/tmp/base")
        let a = PinnedModelFiles.folder(for: try manifest([:], revision: "aaaaaaaaaaaaaaaa"), base: base)
        let b = PinnedModelFiles.folder(for: try manifest([:], revision: "bbbbbbbbbbbbbbbb"), base: base)
        XCTAssertEqual(a.path, "/tmp/base/Banana Pi/Models/Tiny-Model@aaaaaaaaaaaa")
        XCTAssertNotEqual(a, b)
    }

    func testFilesAreReadyOnlyOnceVerifiedAndStamped() async throws {
        let files = ["config.json": Data("{}".utf8), "weights.bin": Data(repeating: 7, count: 1000)]
        let pin = try manifest(files)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        XCTAssertFalse(PinnedModelFiles.isChecked(pin, in: folder), "present but never checked")
        try await PinnedModelFiles.verify(pin, in: folder)
        try PinnedModelFiles.stamp(pin, in: folder)
        XCTAssertTrue(PinnedModelFiles.isChecked(pin, in: folder))
        // A stamp from another revision doesn't count.
        XCTAssertFalse(PinnedModelFiles.isChecked(try manifest(files, revision: "fedcba9876543210"), in: folder))
    }

    func testAFileWhoseSizeChangedIsNoLongerReady() async throws {
        let files = ["weights.bin": Data(repeating: 1, count: 64)]
        let pin = try manifest(files)
        try files["weights.bin"]!.write(to: folder.appendingPathComponent("weights.bin"))
        try await PinnedModelFiles.verify(pin, in: folder)
        try PinnedModelFiles.stamp(pin, in: folder)
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent("weights.bin"))
        XCTAssertFalse(PinnedModelFiles.isChecked(pin, in: folder))
    }

    func testATamperedFileIsRejectedAndDeletedSoItIsFetchedAgain() async throws {
        let pin = try manifest(["weights.bin": Data(repeating: 1, count: 64)])
        let url = folder.appendingPathComponent("weights.bin")
        try Data(repeating: 2, count: 64).write(to: url)
        do {
            try await PinnedModelFiles.verify(pin, in: folder)
            XCTFail("a checksum mismatch must fail")
        } catch let failure as PinnedModelFailure {
            XCTAssertEqual(failure.message, "weights.bin didn’t match its checksum")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAMissingFileIsIncomplete() async throws {
        let pin = try manifest(["weights.bin": Data(repeating: 1, count: 64)])
        do {
            try await PinnedModelFiles.verify(pin, in: folder)
            XCTFail("a missing file must fail")
        } catch let failure as PinnedModelFailure {
            XCTAssertEqual(failure.message, "weights.bin is incomplete")
        }
    }
}
