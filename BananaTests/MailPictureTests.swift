import XCTest
import ImageIO
import UniformTypeIdentifiers

final class MailPictureTests: XCTestCase {
    private func pngData(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testDecodeIsBoundedByTheRequestedSize() throws {
        let image = try XCTUnwrap(MailPictureLoader.decode(try pngData(width: 3_000, height: 1_500), maxPixel: 600))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 600)
        XCTAssertEqual(Double(image.width) / Double(image.height), 2, accuracy: 0.05)
    }

    func testSmallPictureIsNotEnlarged() throws {
        let image = try XCTUnwrap(MailPictureLoader.decode(try pngData(width: 40, height: 20), maxPixel: 600))
        XCTAssertLessThanOrEqual(image.width, 40)
    }

    func testCorruptDataIsNotAPicture() {
        XCTAssertNil(MailPictureLoader.decode(Data([1, 2, 3, 4]), maxPixel: 600))
    }

    func testRemotePicturesAreNotLoadableUntilTheProxyExists() {
        XCTAssertNil(MailImageSource.url(for: URL(string: "https://img.example.com/a.png")!, account: "a"))
    }

    func testLoaderServesRepeatsFromItsCacheAndAsksOnce() async throws {
        let data = try pngData(width: 100, height: 50)
        let calls = CallCounter()
        let loader = MailPictureLoader()
        let first = await loader.image(key: "k", maxPixel: 100) { await calls.bump(); return data }
        let second = await loader.image(key: "k", maxPixel: 100) { await calls.bump(); return data }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }
}

private actor CallCounter {
    var count = 0
    func bump() { count += 1 }
}
