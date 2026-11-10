import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Sender images on the device (`MailSenderImages`): one request for many rows, one answer per
/// address however many rows ask, bytes kept on disk, and nothing asked again that is known.
final class MailSenderImagesTests: XCTestCase {
    /// A fake Banana Cloud: what it answers, and what it was asked.
    actor FakeCloud {
        var answers: [String: MailSenderImages.Answer] = [:]
        var pendingOnce: Set<String> = []
        var lookups: [[String]] = []
        var downloads: [String] = []
        var images: [String: Data] = [:]
        var fails = false

        func set(_ address: String, _ answer: MailSenderImages.Answer) { answers[address] = answer }
        func image(_ id: String, _ data: Data) { images[id] = data }
        func holdOnce(_ address: String) { pendingOnce.insert(address) }
        func failing(_ value: Bool) { fails = value }

        func lookup(_ addresses: [String]) throws -> [String: MailSenderImages.Answer] {
            lookups.append(addresses)
            if fails { throw URLError(.notConnectedToInternet) }
            var out: [String: MailSenderImages.Answer] = [:]
            for address in addresses {
                if pendingOnce.remove(address) != nil { out[address] = .pending } else { out[address] = answers[address] ?? MailSenderImages.Answer.none }
            }
            return out
        }
        func bytes(_ id: String) -> Data? { downloads.append(id); return images[id] }

        var service: MailSenderImages.Service {
            MailSenderImages.Service(lookup: { try await self.lookup($0) }, bytes: { await self.bytes($0) })
        }
    }

    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sender-images-\(UUID().uuidString)")
        MailSenderImages.memory.removeAllObjects()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func png(_ shade: CGFloat, side: Int = 64) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: shade, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private let idA = String(repeating: "a", count: 64)
    private let idB = String(repeating: "b", count: 64)

    func testManyRowsAskingAtOnceMakeOneRequestWithEachAddressOnce() async {
        let cloud = FakeCloud()
        await cloud.set("ann@example.com", .image(idA))
        await cloud.image(idA, png(0.1))
        let store = MailSenderImages(directory: folder, service: await cloud.service)
        await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<10 { group.addTask { await store.image(for: "Ann@Example.com", px: 64) } }
            group.addTask { await store.image(for: "bo@example.com", px: 64) }
            group.addTask { await store.image(for: "cy@example.com", px: 64) }
            var pictures = 0
            for await image in group where image != nil { pictures += 1 }
            XCTAssertEqual(pictures, 10)
        }
        let lookups = await cloud.lookups
        XCTAssertEqual(lookups.count, 1, "one request for every row that asked")
        XCTAssertEqual(Set(lookups[0]), ["ann@example.com", "bo@example.com", "cy@example.com"])
        XCTAssertEqual(lookups[0].count, 3)
        let downloads = await cloud.downloads
        XCTAssertEqual(downloads, [idA], "the bytes once")
    }

    func testWhatIsKnownIsNotAskedAgainEvenAfterARelaunch() async {
        let cloud = FakeCloud()
        await cloud.set("ann@example.com", .image(idA))
        await cloud.image(idA, png(0.2))
        let first = MailSenderImages(directory: folder, service: await cloud.service)
        _ = await first.image(for: "ann@example.com", px: 64)
        _ = await first.image(for: "nobody@example.com", px: 64)
        await first.save()
        MailSenderImages.memory.removeAllObjects()
        let before = await cloud.lookups.count

        let again = MailSenderImages(directory: folder, service: await cloud.service)
        let image = await again.image(for: "ann@example.com", px: 64)
        XCTAssertNotNil(image)
        let nobody = await again.image(for: "nobody@example.com", px: 64)
        XCTAssertNil(nobody)
        let lookups = await cloud.lookups.count
        let downloads = await cloud.downloads.count
        XCTAssertEqual(lookups, before, "the relaunch asked nothing")
        XCTAssertEqual(downloads, 1, "the bytes came from disk")
    }

    func testAKnownPictureIsAskedAgainAfterItsTimeAndNoneSooner() async {
        let clock = Clock()
        let cloud = FakeCloud()
        await cloud.set("ann@example.com", .image(idA))
        await cloud.image(idA, png(0.3))
        let store = MailSenderImages(directory: folder, service: await cloud.service, now: { clock.now })
        _ = await store.imageID(for: "ann@example.com")
        _ = await store.imageID(for: "nobody@example.com")
        clock.advance(MailSenderImages.noneFor + 1)
        _ = await store.imageID(for: "ann@example.com")
        _ = await store.imageID(for: "nobody@example.com")
        var lookups = await cloud.lookups
        XCTAssertEqual(lookups.flatMap { $0 }, ["ann@example.com", "nobody@example.com", "nobody@example.com"])
        clock.advance(MailSenderImages.knownFor)
        _ = await store.imageID(for: "ann@example.com")
        lookups = await cloud.lookups
        XCTAssertEqual(lookups.last, ["ann@example.com"])
    }

    func testStillLookingIsAskedAgainShortlyAndAFailureWaitsBeforeTheNextTry() async {
        let cloud = FakeCloud()
        await cloud.set("slow@example.com", .image(idB))
        await cloud.holdOnce("slow@example.com")
        let store = MailSenderImages(directory: folder, service: await cloud.service, pendingDelay: .milliseconds(10))
        let id = await store.imageID(for: "slow@example.com")
        XCTAssertEqual(id, idB)
        let lookups = await cloud.lookups.count
        XCTAssertEqual(lookups, 2)

        await cloud.failing(true)
        let down = await store.imageID(for: "down@example.com")
        let downAgain = await store.imageID(for: "down@example.com")
        XCTAssertNil(down)
        XCTAssertNil(downAgain)
        let afterFailure = await cloud.lookups.count
        XCTAssertEqual(afterFailure, 3, "a failure is not asked again at once")
        let kept = await store.knownEntry("down@example.com")
        XCTAssertNil(kept, "and is not kept as an answer")
    }

    func testTheDiskKeepsTheMostRecentlyShownUnderItsLimit() async throws {
        let cloud = FakeCloud()
        let big = Data(repeating: 1, count: 4_000)
        let ids = (0..<5).map { String(repeating: String($0), count: 64) }
        for id in ids { await cloud.image(id, big) }
        let store = MailSenderImages(directory: folder, service: await cloud.service, diskLimit: 10_000)
        for id in ids { _ = await store.data(for: id) }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.count == 64 }
        XCTAssertLessThanOrEqual(left.count * 4_000, 10_000)
        XCTAssertTrue(left.contains(ids[4]), "the newest stays")
        XCTAssertFalse(left.contains(ids[0]), "the oldest goes")
        let escape = await store.data(for: "../index.json")
        XCTAssertNil(escape, "only an id names a file")
    }

    func testAFaceKnowsWhoseItIsWhateverTheCase() {
        let face = MailFace(MailPerson(name: "Ann", address: " Ann@Example.com", isMe: false, isKnown: false, fromTheirMail: false))
        XCTAssertEqual(face.address, "ann@example.com")
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return at }
        func advance(_ seconds: TimeInterval) { lock.lock(); at += seconds; lock.unlock() }
    }
}
