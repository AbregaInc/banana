import AVFoundation
import ImageIO
import simd
import UniformTypeIdentifiers
import XCTest

/// Depth from meal photos (docs/design/MEAL-LEARNING.md §8): measuring plates, bowls and food on
/// ray-cast depth maps of known size, reading a depth map out of a photo, and what the estimate
/// and the review are told.
final class MealPhotoDepthTests: XCTestCase {
    // MARK: - Measuring

    func testAPlateFromAboveMeasuresItsSizeAndTheFoodOnIt() throws {
        let depth = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.plate(with: DepthScene.dome)).map()))
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(depth.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)
        XCTAssertEqual(try XCTUnwrap(depth.heightCm), 4, accuracy: 0.5)
        XCTAssertEqual(depth.source, .portrait)
    }

    func testFromAnAngleWhatTheFoodHidesIsFilledIn() throws {
        let puck = try XCTUnwrap(MealPhotoDepth.measure(
            DepthScene(surface: DepthScene.plate(with: DepthScene.puck), tiltDegrees: 30).map()))
        XCTAssertEqual(puck.kind, .plate)
        XCTAssertEqual(puck.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(puck.foodMl), DepthScene.puckMl, accuracy: DepthScene.puckMl * 0.15)
        XCTAssertEqual(try XCTUnwrap(puck.heightCm), 3, accuracy: 0.5)

        let dome = try XCTUnwrap(MealPhotoDepth.measure(
            DepthScene(surface: DepthScene.plate(with: DepthScene.dome), tiltDegrees: 45).map()))
        XCTAssertEqual(dome.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(dome.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)
    }

    func testABowlIsMeasuredOnlyAcross() throws {
        for tilt in [0.0, 30] {
            let depth = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.bowl, tiltDegrees: tilt).map()))
            XCTAssertEqual(depth.kind, .bowl, "tilted \(tilt)°")
            XCTAssertEqual(depth.acrossCm, 15, accuracy: 1.5)
            XCTAssertNil(depth.foodMl, "a camera above a bowl can't see how deep it goes")
            XCTAssertNil(depth.heightCm)
        }
    }

    func testANoisyMapWithGapsStillMeasures() throws {
        let map = DepthScene(surface: DepthScene.plate(with: DepthScene.dome)).map(noise: 0.002, holes: 0.05)
        XCTAssertGreaterThan(map.depths.filter(\.isNaN).count, map.depths.count / 30, "the scene has gaps")
        let depth = try XCTUnwrap(MealPhotoDepth.measure(map))
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(depth.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)
    }

    func testRelativeDepthMeasuresNothingAndSaysWhy() {
        let map = DepthScene(surface: DepthScene.plate(with: DepthScene.dome)).map(absolute: false)
        XCTAssertNil(MealPhotoDepth.measure(map))
        XCTAssertTrue(MealPhotoDepth.attempt(map).note.contains("relative"))
    }

    func testAnEmptyPlateIsMeasuredWithNoFood() throws {
        let depth = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.plate()).map()))
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 26, accuracy: 1.5)
        XCTAssertNil(depth.foodMl)
    }

    func testAPlateFillingMostOfTheShotStillStandsOnTheTable() throws {
        // At 25 cm the plate's floor covers more of the photo than the table does: the table is
        // the parallel plane a little below it.
        let depth = try XCTUnwrap(MealPhotoDepth.measure(
            DepthScene(surface: DepthScene.plate(with: DepthScene.dome), distance: 0.25).map()))
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(depth.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)
    }

    func testFoodWithoutAPlateIsMeasuredFromTheTable() throws {
        let heap = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.dome).map()))
        XCTAssertEqual(heap.kind, .unknown)
        XCTAssertEqual(heap.acrossCm, 12, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(heap.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)

        let burger = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.burger).map()))
        XCTAssertEqual(burger.kind, .unknown)
        XCTAssertEqual(try XCTUnwrap(burger.foodMl), DepthScene.burgerMl, accuracy: DepthScene.burgerMl * 0.15)
    }

    func testARectangularPlateIsMeasuredAlongItsLength() throws {
        let depth = try XCTUnwrap(MealPhotoDepth.measure(DepthScene(surface: DepthScene.tray(with: DepthScene.dome)).map()))
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 30, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(depth.foodMl), DepthScene.domeMl, accuracy: DepthScene.domeMl * 0.15)
    }

    func testTheSameMapAlwaysMeasuresTheSame() {
        let map = DepthScene(surface: DepthScene.plate(with: DepthScene.puck), tiltDegrees: 30).map(noise: 0.002)
        XCTAssertEqual(MealPhotoDepth.measure(map), MealPhotoDepth.measure(map))
    }

    // MARK: - Reading a photo's depth

    func testReadingTurnsTheMapUprightWithItsPhoto() throws {
        // Stored as the sensor sees it, 8 × 6, with the photo to be turned a quarter clockwise.
        var depths = [Float](repeating: 0.4, count: 8 * 6)
        depths[0] = 0.1   // stored top left → shown top right
        depths[7] = 0.2   // stored top right → shown bottom right
        let data = try DepthPhoto.make(depths: depths, width: 8, height: 6, orientation: .right, focal35: 26)
        let map = try XCTUnwrap(MealPhotoDepth.read(from: data))
        XCTAssertEqual(map.width, 6)
        XCTAssertEqual(map.height, 8)
        // A JPEG keeps its depth as an 8-bit image between the nearest and furthest reading:
        // 1/255 of the range, give or take its compression.
        XCTAssertEqual(map.depths[5], 0.1, accuracy: 0.003)
        XCTAssertEqual(map.depths[7 * 6 + 5], 0.2, accuracy: 0.003)
        XCTAssertEqual(map.depths[0], 0.4, accuracy: 0.003)
        XCTAssertTrue(map.isAbsolute)
        XCTAssertEqual(map.stored, "depth")
        XCTAssertEqual(map.intrinsics, .exif)
        // 26 mm on the 35 mm frame's 43.27 mm diagonal, across the map's 10-pixel diagonal.
        XCTAssertEqual(map.fx, 26 * 10 / 43.27, accuracy: 0.01)
        XCTAssertEqual(map.fy, map.fx)
    }

    func testReadingUsesTheCalibrationScaledToTheMap() throws {
        let data = try DepthPhoto.make(depths: [Float](repeating: 0.4, count: 8 * 6), width: 8, height: 6, focal35: 26,
                                       calibration: .init(fx: 3_000, fy: 3_010, cx: 2_000, cy: 1_500, width: 4_000, height: 3_000))
        let map = try XCTUnwrap(MealPhotoDepth.read(from: data, source: .lidar))
        XCTAssertEqual(map.intrinsics, .calibration)
        XCTAssertEqual(map.fx, 6, accuracy: 1e-3)
        XCTAssertEqual(map.fy, 6.02, accuracy: 1e-3)
        XCTAssertEqual(map.cx, 4, accuracy: 1e-3)
        XCTAssertEqual(map.cy, 3, accuracy: 1e-3)
        XCTAssertEqual(map.source, .lidar)
    }

    func testRelativeDisparityIsReadButNotAbsolute() throws {
        let data = try DepthPhoto.make(depths: [Float](repeating: 2.5, count: 8 * 6), width: 8, height: 6, focal35: 26,
                                       disparity: true, accuracy: "relative")
        let map = try XCTUnwrap(MealPhotoDepth.read(from: data))
        XCTAssertEqual(map.stored, "disparity")
        XCTAssertFalse(map.isAbsolute)
        XCTAssertEqual(map.depths[0], 0.4, accuracy: 1e-4, "disparity 2.5 per metre is 0.4 m")
    }

    func testAPhotoWithoutDepthHasNone() {
        XCTAssertNil(MealPhotoDepth.read(from: DepthPhoto.plain()))
        let prepared = MealPhotoImage.prepare(DepthPhoto.plain())
        XCTAssertNotNil(prepared)
        XCTAssertNil(prepared?.depth)
        XCTAssertEqual(prepared?.carriesDepth, false)
    }

    func testPreparingAPhotoMeasuresItsDepthFromTheOriginal() throws {
        let map = DepthScene(surface: DepthScene.plate(with: DepthScene.dome)).map()
        // Calibrated at four times the map's size, as a camera's sensor is.
        let data = try DepthPhoto.make(depths: map.depths, width: map.width, height: map.height,
                                       calibration: .init(fx: map.fx * 4, fy: map.fy * 4, cx: map.cx * 4, cy: map.cy * 4,
                                                          width: map.width * 4, height: map.height * 4))
        let prepared = try XCTUnwrap(MealPhotoImage.prepare(data, maxPixels: 64, depthSource: .lidar))
        XCTAssertTrue(prepared.carriesDepth)
        let depth = try XCTUnwrap(prepared.depth)
        XCTAssertEqual(depth.kind, .plate)
        XCTAssertEqual(depth.acrossCm, 26, accuracy: 1.5)
        XCTAssertEqual(depth.source, .lidar)
        XCTAssertNil(MealPhotoDepth.read(from: prepared.jpeg), "the copy kept has no depth")
    }

    func testTheLensTurnsWithThePhoto() {
        let lens = MealPhotoDepth.Lens(fx: 10, fy: 11, cx: 3, cy: 2)
        XCTAssertEqual(lens.oriented(.up, width: 8, height: 6), lens)
        XCTAssertEqual(lens.oriented(.down, width: 8, height: 6), .init(fx: 10, fy: 11, cx: 5, cy: 4))
        XCTAssertEqual(lens.oriented(.right, width: 8, height: 6), .init(fx: 11, fy: 10, cx: 4, cy: 3))
        XCTAssertEqual(lens.oriented(.left, width: 8, height: 6), .init(fx: 11, fy: 10, cx: 2, cy: 5))
    }

    // MARK: - Kept and synced

    func testPhotoDepthRoundTrips() throws {
        let depth = PhotoDepth(kind: .plate, acrossCm: 26.3, foodMl: 541, heightCm: 4.1, source: .lidar)
        XCTAssertEqual(try JSONDecoder().decode(PhotoDepth.self, from: JSONEncoder().encode(depth)), depth)
    }

    func testPhotoDepthDecodesWhateverANewerBuildWrites() throws {
        let newer = #"{"kind":"tray","acrossCm":31,"foodMl":"lots","heightCm":2.5,"source":"stereo","fresh":true}"#
        let depth = try JSONDecoder().decode(PhotoDepth.self, from: Data(newer.utf8))
        XCTAssertEqual(depth.kind, .unknown)
        XCTAssertEqual(depth.acrossCm, 31)
        XCTAssertNil(depth.foodMl)
        XCTAssertEqual(depth.heightCm, 2.5)
        XCTAssertEqual(depth.source, .portrait)

        // Not even an object: the photo keeps its place, with a measurement nothing reads.
        let photo = #"{"id":"6F1C2C1E-4C0B-4A44-9E43-6F7A0A4B3F10","depth":"26 cm"}"#
        let ref = try JSONDecoder().decode(MealPhotoRef.self, from: Data(photo.utf8))
        XCTAssertEqual(ref.depth?.isUsable, false)
        XCTAssertEqual(MealPhotoDepth.lines(ref.depth.map { [$0] } ?? []), [])
    }

    func testAPhotoRefFromBeforeDepthDecodes() throws {
        let old = #"{"id":"6F1C2C1E-4C0B-4A44-9E43-6F7A0A4B3F10","takenAt":800000000,"assetID":"A/L0/001","cloudKey":"abc"}"#
        let ref = try JSONDecoder().decode(MealPhotoRef.self, from: Data(old.utf8))
        XCTAssertEqual(ref.cloudKey, "abc")
        XCTAssertNil(ref.depth)

        var measured = ref
        measured.depth = PhotoDepth(kind: .bowl, acrossCm: 15)
        let item = MealInboxItem(eatenAt: Date(timeIntervalSince1970: 1_800_000_000), photos: [measured], state: .ready, origin: .picked)
        let back = try JSONDecoder().decode(MealInboxItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back.photos.first?.depth, measured.depth)
    }

    // MARK: - What the estimate and the review are told

    func testLinesSayTheSizesRounded() {
        let plate = PhotoDepth(kind: .plate, acrossCm: 26.4, foodMl: 537, heightCm: 3.6)
        XCTAssertEqual(MealPhotoDepth.lines([plate]),
                       ["the plate is about 26 cm across; the food on it is about 540 ml and stands up to 4 cm"])
        XCTAssertEqual(MealPhotoDepth.lines([PhotoDepth(kind: .plate, acrossCm: 22.6)]), ["the plate is about 23 cm across"])
        XCTAssertEqual(MealPhotoDepth.lines([PhotoDepth(kind: .bowl, acrossCm: 14.8)]), ["the bowl is about 15 cm across"])
        XCTAssertEqual(MealPhotoDepth.lines([PhotoDepth(kind: .unknown, acrossCm: 11.2, foodMl: 262, heightCm: 3.9)]),
                       ["the food is about 11 cm across and about 260 ml, standing up to 4 cm"])
        // Two photos of the same plate say it once; one nothing can read says nothing.
        XCTAssertEqual(MealPhotoDepth.lines([plate, plate, PhotoDepth(kind: .unknown, acrossCm: 0)]).count, 1)
        XCTAssertEqual(MealPhotoDepth.lines([]), [])
    }

    func testTheReviewCaption() {
        XCTAssertEqual(MealPhotoDepth.caption([PhotoDepth(kind: .plate, acrossCm: 26.4, foodMl: 537, heightCm: 3.6)]),
                       "Measured: plate 26 cm \u{00B7} food \u{2248} 540 ml")
        XCTAssertEqual(MealPhotoDepth.caption([PhotoDepth(kind: .bowl, acrossCm: 15),
                                               PhotoDepth(kind: .plate, acrossCm: 20)]),
                       "Measured: bowl 15 cm \u{00B7} plate 20 cm")
        XCTAssertNil(MealPhotoDepth.caption([]))
        XCTAssertNil(MealPhotoDepth.caption([PhotoDepth(kind: .plate, acrossCm: 0)]))
    }
}

// MARK: - Made-up scenes

/// A camera above a table, ray-cast into a depth map: what a phone over a plate would read.
struct DepthScene {
    /// Height above the table in metres at a spot on it; the photo is aimed at (0, 0).
    var surface: (SIMD2<Double>) -> Double
    /// Nothing stands higher than this.
    var tallest = 0.12
    /// Metres from the camera to (0, 0) on the table.
    var distance = 0.40
    /// Away from straight down, the camera on the −y side.
    var tiltDegrees = 0.0
    /// A LiDAR map's size, and a wide camera's focal length for it.
    var width = 256
    var height = 192
    var fx = 210.0

    func map(noise: Double = 0, holes: Double = 0, absolute: Bool = true, seed: UInt64 = 7) -> MealPhotoDepth.DepthMap {
        let tilt = tiltDegrees * .pi / 180
        let eye = SIMD3(0, -distance * sin(tilt), distance * cos(tilt))
        let forward = simd_normalize(-eye)
        let right = SIMD3<Double>(1, 0, 0)
        let down = simd_cross(forward, right)
        let cx = Double(width) / 2, cy = Double(height) / 2
        var random = MealPhotoDepth.SplitMix(state: seed)
        var depths = [Float](repeating: .nan, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                // Its forward part is 1, so how far along it the ray hits is the depth the camera reads.
                let ray = right * ((Double(u) - cx) / fx) + down * ((Double(v) - cy) / fx) + forward
                guard ray.z < 0 else { continue }
                func clear(_ t: Double) -> Bool {
                    let p = eye + ray * t
                    return p.z > surface(SIMD2(p.x, p.y))
                }
                // Down from `tallest` a millimetre at a time, then halving.
                let step = 0.001 / simd_length(ray)
                var t = max(0, (eye.z - tallest) / -ray.z)
                while clear(t), t < 5 { t += step }
                var low = max(0, t - step), high = t
                for _ in 0..<24 {
                    let mid = (low + high) / 2
                    if clear(mid) { low = mid } else { high = mid }
                }
                var depth = high
                if noise > 0 {
                    let a = max(1e-12, Double.random(in: 0..<1, using: &random)), b = Double.random(in: 0..<1, using: &random)
                    depth += noise * (-2 * log(a)).squareRoot() * cos(2 * .pi * b)   // Box–Muller
                }
                if holes > 0, Double.random(in: 0..<1, using: &random) < holes { continue }
                depths[v * width + u] = Float(depth)
            }
        }
        return MealPhotoDepth.DepthMap(width: width, height: height, depths: depths, fx: fx, fy: fx, cx: cx, cy: cy,
                                       isAbsolute: absolute)
    }

    /// A 26 cm plate: a floor 8 mm up out to 10 cm, a rim rising to 2 cm, flat for its last 5 mm.
    static func plate(with food: @escaping (SIMD2<Double>) -> Double = { _ in 0 }) -> (SIMD2<Double>) -> Double {
        { spot in
            let r = simd_length(spot)
            guard r < 0.13 else { return 0 }
            if r < 0.10 { return 0.008 + food(spot) }
            return r < 0.125 ? 0.008 + (r - 0.10) / 0.025 * 0.012 : 0.02
        }
    }

    /// A 30 × 20 cm plate: the same floor, a rim 2.5 cm wide rising to 2 cm.
    static func tray(with food: @escaping (SIMD2<Double>) -> Double) -> (SIMD2<Double>) -> Double {
        { spot in
            let inside = min(0.15 - abs(spot.x), 0.10 - abs(spot.y))
            guard inside > 0 else { return 0 }
            if inside > 0.025 { return 0.008 + food(spot) }
            return inside < 0.005 ? 0.02 : 0.008 + (0.025 - inside) / 0.02 * 0.012
        }
    }

    /// A mound 12 cm across and 4 cm high (part of a sphere), a little off the middle.
    static let dome = { (spot: SIMD2<Double>) -> Double in
        let r = simd_distance(spot, SIMD2(0.01, 0)), sphere = 0.065
        return r < 0.06 ? (sphere * sphere - r * r).squareRoot() - (sphere - 0.04) : 0
    }
    static let domeMl = Double.pi * 0.04 * (3 * 0.06 * 0.06 + 0.04 * 0.04) / 6 * 1_000_000

    /// A 10 cm round, 3 cm high, with straight sides.
    static let puck = { (spot: SIMD2<Double>) -> Double in simd_distance(spot, SIMD2(-0.01, 0.01)) < 0.05 ? 0.03 : 0 }
    static let puckMl = Double.pi * 0.05 * 0.05 * 0.03 * 1_000_000

    /// A 15 cm bowl, 6 cm high, with soup 4 cm up.
    static let bowl = { (spot: SIMD2<Double>) -> Double in
        let r = simd_length(spot)
        if r >= 0.075 { return 0 }
        if r >= 0.07 { return 0.06 }
        return max(0.04, 0.012 + 0.048 * (r / 0.07) * (r / 0.07))
    }

    /// A burger straight on the table, 11 cm across and 7 cm high.
    static let burger = { (spot: SIMD2<Double>) -> Double in simd_length(spot) < 0.055 ? 0.07 : 0 }
    static let burgerMl = Double.pi * 0.055 * 0.055 * 0.07 * 1_000_000
}

/// Photos carrying a depth map the way a camera saves one: the map as auxiliary data, with Apple's
/// depth metadata (accuracy, and the lens calibration when given).
enum DepthPhoto {
    struct Calibration {
        var fx: Double, fy: Double, cx: Double, cy: Double
        var width: Int, height: Int
    }

    static func make(depths: [Float], width: Int, height: Int, orientation: CGImagePropertyOrientation = .up,
                     focal35: Int? = nil, calibration: Calibration? = nil, disparity: Bool = false,
                     accuracy: String = "absolute") throws -> Data {
        let namespace = "http://ns.apple.com/depthData/1.0/" as CFString
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, "depthData" as CFString, nil)
        func set(_ name: String, _ value: String) {
            CGImageMetadataSetValueWithPath(metadata, nil, "depthData:\(name)" as CFString, value as CFString)
        }
        func set(_ name: String, _ values: [Double]) {
            let items = values.map {
                CGImageMetadataTagCreate(namespace, "depthData" as CFString, name as CFString, .string, String($0) as CFString)!
            }
            let tag = CGImageMetadataTagCreate(namespace, "depthData" as CFString, name as CFString, .arrayOrdered, items as CFArray)!
            CGImageMetadataSetTagWithPath(metadata, nil, "depthData:\(name)" as CFString, tag)
        }
        set("Accuracy", accuracy)
        set("Filtered", "true")
        set("Quality", "high")
        if let c = calibration {
            set("IntrinsicMatrix", [c.fx, 0, 0, 0, c.fy, 0, c.cx, c.cy, 1])   // column by column
            set("IntrinsicMatrixReferenceWidth", String(c.width))
            set("IntrinsicMatrixReferenceHeight", String(c.height))
            set("ExtrinsicMatrix", [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
            set("PixelSize", "0.0014")
            set("LensDistortionLookupTable", [0, 0])
            set("InverseLensDistortionLookupTable", [0, 0])
            set("LensDistortionCenterOffsetX", String(c.cx))
            set("LensDistortionCenterOffsetY", String(c.cy))
        }
        let description: [CFString: Any] = [
            "PixelFormat" as CFString: disparity ? kCVPixelFormatType_DisparityFloat32 : kCVPixelFormatType_DepthFloat32,
            "Width" as CFString: width, "Height" as CFString: height, "BytesPerRow" as CFString: width * 4,
        ]
        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: depths.withUnsafeBufferPointer { Data(buffer: $0) },
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: metadata,
        ]
        let depth = try AVDepthData(fromDictionaryRepresentation: info)
        var type: NSString?
        let auxiliary = try XCTUnwrap(depth.dictionaryRepresentation(forAuxiliaryDataType: &type))

        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        if let focal35 { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFocalLenIn35mmFilm: focal35] }
        CGImageDestinationAddImage(destination, image(width: width * 4, height: height * 4), properties as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, try XCTUnwrap(type) as CFString, auxiliary as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A photo with no depth at all.
    static func plain() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(width: 64, height: 48), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
