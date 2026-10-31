import XCTest

/// A package photo picked from Photos (`PackagePhoto`): its barcode is read as the camera reads
/// one, and a photo with none says so, to go to its label.
///
/// The Simulator has no barcode detector ("Failed to create barcode detector", 15 Oct 2026): these
/// run on a device. On the Mac, `PackagePhoto.swift` is checked the same way by compiling it into
/// a small program.
final class PackagePhotoTests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the Simulator has no barcode detector")
        #endif
    }

    func testTheBarcodeInAPhotoIsRead() async throws {
        let data = try XCTUnwrap(PackagePhoto.barcodePicture("00772914"))
        let image = try XCTUnwrap(PackagePhoto.image(data))
        let codes = await PackagePhoto.barcodes(in: image)
        XCTAssertEqual(codes, ["00772914"])
    }

    func testAPhotoWithNoBarcodeHasNone() async throws {
        let data = try XCTUnwrap(PackagePhoto.barcodePicture(nil))
        let image = try XCTUnwrap(PackagePhoto.image(data))
        let codes = await PackagePhoto.barcodes(in: image)
        XCTAssertEqual(codes, [])
    }

    func testOnlyProductBarcodesCount() async throws {
        // Code 128 carries anything; a word on a package isn't a product.
        let data = try XCTUnwrap(PackagePhoto.barcodePicture("BANANA"))
        let image = try XCTUnwrap(PackagePhoto.image(data))
        let codes = await PackagePhoto.barcodes(in: image)
        XCTAssertEqual(codes, [])
    }
}
