import AVFoundation
import Foundation
import ImageIO
import simd

/// What a meal photo's depth measured (docs/design/MEAL-LEARNING.md §8): the plate's or bowl's
/// size across, and the food's volume and height above the plate. A few numbers per photo, kept on
/// `MealPhotoRef.depth` and synced with it; the depth map itself is read once, on import, and let go.
struct PhotoDepth: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case plate, bowl
        /// Something on the table that isn't a round plate or bowl — food straight on the table, a
        /// burger, a heaped dish — measured from the table up.
        case unknown
    }

    /// Which camera the depth came from, so measured meals can be compared by it later.
    enum Source: String, Codable, Sendable {
        /// A Portrait photo: depth the Camera app worked out from its lenses.
        case portrait
        /// Banana's own camera on a phone with LiDAR.
        case lidar
    }

    var kind: Kind
    /// The plate's or bowl's size across; for `.unknown`, the thing's longest extent.
    var acrossCm: Double
    /// The food above the plate (above the table for `.unknown`). Nil for a bowl, whose depth a
    /// camera above it can't see, and when nothing measurable stands on the plate.
    var foodMl: Double?
    /// How high the food stands above the plate.
    var heightCm: Double?
    var source: Source

    init(kind: Kind, acrossCm: Double, foodMl: Double? = nil, heightCm: Double? = nil, source: Source = .portrait) {
        self.kind = kind
        self.acrossCm = acrossCm
        self.foodMl = foodMl
        self.heightCm = heightCm
        self.source = source
    }

    /// Worth telling anyone: a record a newer build wrote in a shape this one can't read comes out
    /// with no size, and is left out rather than said wrong.
    var isUsable: Bool { acrossCm.isFinite && acrossCm > 0 }

    private enum CodingKeys: String, CodingKey { case kind, acrossCm, foodMl, heightCm, source }

    /// Tolerant, like every meal record: a value a newer build writes must never cost the photo or
    /// its meal. Never throws — not even for a shape it can't read at all, which decodes unusable.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            kind = .unknown
            acrossCm = 0
            source = .portrait
            return
        }
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .unknown
        acrossCm = (try? c.decodeIfPresent(Double.self, forKey: .acrossCm)) ?? 0
        foodMl = try? c.decodeIfPresent(Double.self, forKey: .foodMl)
        heightCm = try? c.decodeIfPresent(Double.self, forKey: .heightCm)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .portrait
    }
}

/// Reading a photo's depth map and measuring the plate and the food in it. ImageIO + AVFoundation
/// to read (iOS and macOS alike); the measuring is plain arithmetic, so it's tested on made-up maps.
enum MealPhotoDepth {
    /// One photo's depth, upright like the photo. Never stored: only its measurement is kept.
    struct DepthMap: Sendable {
        /// Where the focal length came from — what the probe reports, since sizes scale with it.
        enum Intrinsics: String, Sendable {
            /// The camera's own calibration, saved with the depth.
            case calibration
            /// The photo's 35 mm-equivalent focal length.
            case exif
            /// Neither: nothing can be sized.
            case none
        }

        var width: Int
        var height: Int
        /// Metres from the camera along its axis, row by row; NaN where there's no reading.
        var depths: [Float]
        /// Focal lengths and principal point, in this map's pixels.
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double
        /// Real metres. A Portrait photo's depth is often only relative — good for blurring the
        /// background, useless for sizes.
        var isAbsolute: Bool
        var intrinsics: Intrinsics = .calibration
        var source: PhotoDepth.Source = .portrait
        /// How the photo stored it ("depth" or "disparity"), for the probe.
        var stored = "depth"
    }
}

// MARK: - Reading a photo's depth

extension MealPhotoDepth {
    /// The 35 mm frame's diagonal. A 35 mm-equivalent focal length matches fields of view along the
    /// diagonal, so a 4:3 photo's long side is about 34.6 mm of film, not the full 36.
    static let filmDiagonalMm = 43.27

    /// The depth map in a photo, or nil when it has none. `source` says which camera took it: the
    /// file can't tell a Portrait photo from one Banana's camera took with LiDAR.
    static func read(from data: Data, source: PhotoDepth.Source = .portrait) -> DepthMap? {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var stored = "depth"
        var info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(image, 0, kCGImageAuxiliaryDataTypeDepth) as? [AnyHashable: Any]
        if info == nil {
            info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(image, 0, kCGImageAuxiliaryDataTypeDisparity) as? [AnyHashable: Any]
            stored = "disparity"
        }
        guard let info, var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        let isAbsolute = depth.depthDataAccuracy == .absolute
        // Read before turning it upright: the calibration describes the sensor as it was.
        let calibration = depth.cameraCalibrationData
        if depth.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let nativeWidth = CVPixelBufferGetWidth(depth.depthDataMap)
        let nativeHeight = CVPixelBufferGetHeight(depth.depthDataMap)
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]

        var lens = Lens(fx: 0, fy: 0, cx: Double(nativeWidth) / 2, cy: Double(nativeHeight) / 2)
        var intrinsics = DepthMap.Intrinsics.none
        if let calibration, calibration.intrinsicMatrixReferenceDimensions.width > 0,
           calibration.intrinsicMatrixReferenceDimensions.height > 0 {
            // Calibrated at the sensor's full size; the map is the same view, smaller.
            let matrix = calibration.intrinsicMatrix
            let sx = Double(nativeWidth) / Double(calibration.intrinsicMatrixReferenceDimensions.width)
            let sy = Double(nativeHeight) / Double(calibration.intrinsicMatrixReferenceDimensions.height)
            lens = Lens(fx: Double(matrix.columns.0.x) * sx, fy: Double(matrix.columns.1.y) * sy,
                        cx: Double(matrix.columns.2.x) * sx, cy: Double(matrix.columns.2.y) * sy)
            intrinsics = .calibration
        } else if let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, f35 > 0 {
            let focal = f35 * Double(nativeWidth * nativeWidth + nativeHeight * nativeHeight).squareRoot() / filmDiagonalMm
            lens.fx = focal
            lens.fy = focal
            intrinsics = .exif
        }

        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        if orientation != .up { depth = depth.applyingExifOrientation(orientation) }
        lens = lens.oriented(orientation, width: Double(nativeWidth), height: Double(nativeHeight))

        guard let values = floats(depth.depthDataMap) else { return nil }
        return DepthMap(width: values.width, height: values.height, depths: values.depths,
                        fx: lens.fx, fy: lens.fy, cx: lens.cx, cy: lens.cy,
                        isAbsolute: isAbsolute, intrinsics: intrinsics, source: source, stored: stored)
    }

    /// Focal lengths and principal point in a map's pixels.
    struct Lens: Equatable, Sendable {
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double

        /// The same lens once the map is turned upright like its photo (EXIF orientation: how the
        /// stored image must be turned to be seen the right way up). `width`, `height`: as stored.
        func oriented(_ orientation: CGImagePropertyOrientation, width: Double, height: Double) -> Lens {
            switch orientation {
            case .up: self
            case .upMirrored: Lens(fx: fx, fy: fy, cx: width - cx, cy: cy)
            case .down: Lens(fx: fx, fy: fy, cx: width - cx, cy: height - cy)
            case .downMirrored: Lens(fx: fx, fy: fy, cx: cx, cy: height - cy)
            case .leftMirrored: Lens(fx: fy, fy: fx, cx: cy, cy: cx)
            case .right: Lens(fx: fy, fy: fx, cx: height - cy, cy: cx)
            case .rightMirrored: Lens(fx: fy, fy: fx, cx: height - cy, cy: width - cx)
            case .left: Lens(fx: fy, fy: fx, cx: cy, cy: width - cx)
            @unknown default: self
            }
        }
    }

    /// A Float32 depth buffer's values, with anything that isn't a distance as NaN.
    private static func floats(_ buffer: CVPixelBuffer) -> (width: Int, height: Int, depths: [Float])? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var depths = [Float](repeating: .nan, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let value = row[x]
                if value.isFinite, value > 0 { depths[y * width + x] = value }
            }
        }
        return (width, height, depths)
    }

    /// One line on a map for the probe: its size and kind, and the spread of its readings.
    static func summary(_ map: DepthMap) -> String {
        let readings = map.depths.filter { $0.isFinite }.sorted()
        let share = map.depths.isEmpty ? 0 : readings.count * 100 / map.depths.count
        var text = "\(map.width)\u{00D7}\(map.height) \(map.stored), \(map.isAbsolute ? "absolute" : "relative"), "
            + "intrinsics \(map.intrinsics.rawValue)"
        if map.fx > 0 { text += String(format: " (fx %.0f)", map.fx) }
        if let low = readings.first, let high = readings.last {
            text += String(format: ", z %.2f\u{2013}%.2f m (median %.2f), %ld%% read", low, high, readings[readings.count / 2], share)
        } else {
            text += ", no readings"
        }
        return text
    }
}

// MARK: - Measuring

extension MealPhotoDepth {
    /// The numbers the measuring works with. Heights are metres above the table.
    enum Tuning {
        /// About this many points are kept from a map: a Portrait map is 768 × 576, and averaging it
        /// down keeps measuring quick on import and evens out noise.
        static let gridPoints = 60_000
        static let planeRounds = 250
        static let planeSample = 3_000
        /// How far off the table a point may be and still be the table, at half a metre (more
        /// further away, as the noise is).
        static let tableTolerance = 0.005
        /// Standing on the table: at least this high, or 3 × the table's own noise when that's more.
        static let standMin = 0.006
        static let standMax = 0.012
        /// Food is what stands at least this far above the plate.
        static let foodMin = 0.005
        /// A rim this high is a bowl's when the middle sits lower; a plate's rim is 1–3 cm.
        static let bowlRim = 0.035
        /// A plate's floor is at most this far above the table — more is food on the table itself.
        static let plateFloorMax = 0.02
        /// A plate's rim stands at least this high, and at least `plateDip` above its floor. Food
        /// heaped straight on the table (or on a plate filling the whole photo) rises from its edge.
        static let plateEdge = 0.01
        static let plateDip = 0.003
        /// This share of what's seen at one level (within 4 mm) up to `plateFloorMax` is a floor —
        /// a plate's or a board's — even without a rim.
        static let flatShare = 0.25
        /// An outline this close to a circle (its spread over its radius) is measured across as one.
        static let roundness = 0.05
        /// The plate's surface, from its rim inwards, in this many rings.
        static let rings = 16
        /// How much of the most that could be hidden behind the food is counted (`filled`).
        static let hiddenShare = 0.5
    }

    /// The measurement, or why there's none — the probe logs both.
    struct Attempt: Sendable {
        var depth: PhotoDepth?
        var note: String
    }

    static func measure(_ map: DepthMap) -> PhotoDepth? { attempt(map).depth }

    /// A photo's depth, read and measured; nil when it has none or nothing in it can be measured.
    static func measure(photo data: Data, source: PhotoDepth.Source = .portrait) -> PhotoDepth? {
        read(from: data, source: source).flatMap(measure)
    }

    /// Measures the plate (or bowl) nearest the middle of the photo:
    ///
    /// 1. The table is the plane most points lie on (RANSAC). A close-up can be mostly plate, so a
    ///    parallel plane a little lower, when there's one, is the table instead.
    /// 2. What stands on it nearest the middle, holes and all, is the plate with its food.
    /// 3. Seen from straight above (heights on a grid over the table, not the photo's pixels — a
    ///    meal is rarely shot square on), its outline is fitted with a circle, or when it isn't
    ///    round measured along its longest axis: the size across.
    /// 4. A high rim with a lower middle is a bowl: a camera above it can't see how deep it goes,
    ///    so only its size is kept. A rim above a lower floor, or a broad flat floor, near the
    ///    table, is a plate (or a board): its surface is followed from the rim's crest inwards
    ///    (never rising towards the middle, so food covering the middle doesn't lift it), and the
    ///    food is what stands above it (`Profile`). Anything else — food heaped on the table, a
    ///    burger, a plate filling the whole photo — is measured from the table up.
    /// 5. What the food hides (its far side, from an angle) is filled in along the line of sight,
    ///    half way between nothing and the most that could be there (`filled`).
    static func attempt(_ map: DepthMap) -> Attempt {
        guard map.isAbsolute else { return Attempt(note: "relative depth: near and far, but no real sizes") }
        guard map.fx > 0, map.fy > 0 else { return Attempt(note: "no focal length to size it by") }
        guard map.width >= 16, map.height >= 16, map.depths.count == map.width * map.height else {
            return Attempt(note: "map too small")
        }
        let grid = Grid(map)
        let readings = grid.points.compactMap { $0 }
        guard readings.count >= max(200, grid.points.count / 5) else {
            return Attempt(note: "readings on only \(readings.count * 100 / max(1, grid.points.count))% of the map")
        }
        var random = SplitMix(state: 0x5EED_D3E7)
        guard let table = supportPlane(readings, random: &random) else { return Attempt(note: "no table facing the camera") }
        let heights = grid.points.map { $0.map(table.height) }
        let stand = min(Tuning.standMax, max(Tuning.standMin, 3 * table.rms))
        guard let region = standingRegion(heights, width: grid.width, height: grid.height, above: stand) else {
            return Attempt(note: "nothing standing on the table")
        }

        // From straight above: each point of the region where it lies on the table, and how high.
        let axes = table.axes
        var seen: [(spot: SIMD2<Double>, height: Double)] = []
        var distances: [Double] = []
        for index in region.mask.indices where region.mask[index] {
            guard let point = grid.points[index], let height = heights[index] else { continue }
            seen.append((table.flat(point, axes), height))
            distances.append(point.z)
        }
        let edge = region.edge.compactMap { grid.points[$0].map { table.flat($0, axes) } }
        guard seen.count >= 30, let outline = Outline(edge: edge, inside: seen.map(\.spot)) else {
            return Attempt(note: "too little standing on the table to measure")
        }
        if !outline.round, region.touchesFrame {
            return Attempt(note: "runs off the edge of the photo")
        }

        // Heights on a grid over the table, a few millimetres a cell (about 1.5 map points across).
        let footprint = percentile(distances, 0.5) * Double(grid.step) / map.fx
        let cell = min(0.008, max(0.002, 1.5 * footprint))
        let reach = max(outline.radius, percentile(seen.map { simd_distance($0.spot, outline.centre) }, 0.99))
        let raster = Raster(centre: outline.centre, half: reach + 2 * cell, cell: cell)
        guard raster.side <= 600 else { return Attempt(note: "too big to be a meal") }
        var top = [Double](repeating: -.infinity, count: raster.count)
        for (spot, height) in seen {
            if let k = raster.index(spot) { top[k] = max(top[k], height) }
        }
        // Cells nobody saw: hidden behind what stands there when the photo shows the region at
        // their spot (the far side of the food, from an angle), else outside it.
        let hidden = (0..<raster.count).map { k -> Bool in
            guard !top[k].isFinite else { return false }
            let point = table.point(raster.centre(k), height: 0, axes)
            guard let index = grid.index(of: point, map: map) else { return false }
            return region.mask[index]
        }
        // Rings from the outline in: 1 at the edge, 0 in the middle. Round, by the circle — which
        // a plate cut off by the photo's edge, or the table hidden behind its far rim, doesn't
        // move. Otherwise by how far in from the outline each cell is, whatever the shape.
        var ring = { (k: Int) in simd_distance(raster.centre(k), outline.centre) / outline.radius }
        if !outline.round {
            // What was seen, and what it encloses: the table hidden behind the far rim is outside.
            let inset = insets(enclosed(top.map(\.isFinite), side: raster.side), side: raster.side)
            let deepest = max(1, inset.max() ?? 1)
            ring = { 1 - inset[$0] / deepest }
        }
        let profile = Profile(top.indices.filter { top[$0].isFinite }.map { (ring($0), top[$0]) })

        let rim = profile.typical(0.8...1), middle = profile.typical(0...0.5)
        let kind: PhotoDepth.Kind
        if let rim, rim >= Tuning.bowlRim, (middle ?? rim) < rim - 0.01 {
            kind = .bowl
        } else {
            kind = profile.isPlate ? .plate : .unknown
        }
        let across = outline.across * 100
        let plausible: ClosedRange<Double> = switch kind {
        case .plate: 10...45
        case .bowl: 6...40
        case .unknown: 3...50
        }
        guard plausible.contains(across) else {
            return Attempt(note: String(format: "%@ %.0f cm across: not a meal's size", kind.rawValue, across))
        }
        let notes = String(format: "%@, edge %.1f cm, floor %.1f cm%@, table \u{00B1}%.1f mm, %ld points",
                           outline.round ? "round" : "not round", profile.edge * 100, profile.floor * 100,
                           profile.flat ? " (flat)" : "", table.rms * 1_000, seen.count)
        if kind == .bowl {
            return Attempt(depth: PhotoDepth(kind: .bowl, acrossCm: tenth(across), source: map.source),
                           note: String(format: "bowl %.1f cm, rim %.1f cm high (%@)", across, (rim ?? 0) * 100, notes))
        }

        // The food: how far each cell stands above the plate (the table, with no plate).
        var food = [Double](repeating: .nan, count: raster.count)
        for k in top.indices where top[k].isFinite {
            let above = top[k] - (kind == .plate ? profile.surface(at: ring(k)) : 0)
            food[k] = above >= Tuning.foodMin ? above : 0
        }
        var volume = 0.0
        for k in 0..<raster.count {
            if !food[k].isNaN {
                volume += food[k]
            } else if hidden[k] {
                volume += filled(k, food: food, hidden: hidden, raster: raster)
            }
        }
        let ml = volume * raster.cell * raster.cell * 1_000_000
        let standing = food.filter { !$0.isNaN && $0 > 0 }
        let height = standing.isEmpty ? nil : percentile(standing, 0.98) * 100
        guard ml <= 4_000 else { return Attempt(note: String(format: "%.0f ml: not a meal's size", ml)) }
        if kind == .unknown, ml < 15 {
            return Attempt(note: String(format: "nothing measurable standing there (%.0f ml)", ml))
        }
        let hasFood = ml >= 15
        let depth = PhotoDepth(kind: kind, acrossCm: tenth(across), foodMl: hasFood ? ml.rounded() : nil,
                               heightCm: hasFood ? height.map(tenth) : nil, source: map.source)
        return Attempt(depth: depth, note: String(format: "%@ %.1f cm, food %.0f ml up to %.1f cm (%@)",
                                                 kind.rawValue, across, ml, height ?? 0, notes))
    }

    /// The heights seen, by ring from the outline in (1 at the edge, 0 in the middle).
    struct Profile {
        /// Each seen cell: its ring and how high it stands above the table.
        let cells: [(ring: Double, top: Double)]
        /// The plate's surface by ring, middle first: the lower part of each ring, never rising
        /// towards the middle from the rim's crest — food covering the middle rings would otherwise
        /// lift the plate up to its top. Outside the crest (the plate's outer wall, or depth blurred
        /// between rim and table), the crest's height.
        let surfaces: [Double]
        /// The rim's crest: the highest of the outer half's rings (by their lower part). For a heap
        /// of food, which rises from its edge inwards, that's half way in.
        let edge: Double
        /// The plate's floor: the lowest its surface gets.
        var floor: Double { surfaces.first ?? 0 }
        /// A good share of it at one level a little above the table: the floor of a plate or a board.
        let flat: Bool

        init(_ cells: [(ring: Double, top: Double)]) {
            self.cells = cells
            let rings = Tuning.rings
            var byRing = [[Double]](repeating: [], count: rings)
            for (ring, top) in cells { byRing[min(rings - 1, max(0, Int(ring * Double(rings))))].append(top) }
            let lows = byRing.map { $0.count >= 4 ? MealPhotoDepth.percentile($0, 0.2) : nil }
            let outer = (rings / 2..<rings).filter { lows[$0] != nil }
            let crest = outer.max { lows[$0]! < lows[$1]! } ?? lows.lastIndex { $0 != nil }
            var surfaces = [Double](repeating: 0, count: rings)
            if let crest, let height = lows[crest] {
                var lowest = height
                for index in stride(from: rings - 1, through: 0, by: -1) {
                    if index < crest, let low = lows[index] { lowest = min(lowest, low) }
                    surfaces[index] = lowest
                }
            }
            self.surfaces = surfaces
            edge = crest.flatMap { lows[$0] } ?? 0
            // Levels in 2 mm steps up to a plate floor's highest; the busiest pair of steps.
            var levels = [Int](repeating: 0, count: Int(Tuning.plateFloorMax / 0.002) + 1)
            for (_, top) in cells where top > 0 && top <= Tuning.plateFloorMax {
                levels[min(levels.count - 1, Int(top / 0.002))] += 1
            }
            let busiest = zip(levels, levels.dropFirst()).map { $0 + $1 }.max() ?? 0
            flat = Double(busiest) >= Tuning.flatShare * Double(max(1, cells.count))
        }

        /// The middle height of the cells in these rings.
        func typical(_ rings: ClosedRange<Double>) -> Double? {
            MealPhotoDepth.median(cells.filter { rings.contains($0.ring) }.map(\.top))
        }

        /// A plate (or a board): a rim standing above a lower floor, or a broad flat floor — with
        /// that floor near the table. A heap of food rises from its edge inwards, and has neither.
        var isPlate: Bool {
            guard floor <= Tuning.plateFloorMax else { return false }
            return flat || (edge >= Tuning.plateEdge && edge - floor >= Tuning.plateDip)
        }

        /// The plate's surface at a ring, between ring centres.
        func surface(at ring: Double) -> Double {
            let position = min(Double(surfaces.count) - 1, max(0, ring * Double(surfaces.count) - 0.5))
            let below = Int(position), above = min(surfaces.count - 1, below + 1)
            let t = position - Double(below)
            return surfaces[below] * (1 - t) + surfaces[above] * t
        }
    }

    /// A shape on a square grid with its holes filled: whatever can't reach the grid's edge
    /// without crossing it.
    static func enclosed(_ shape: [Bool], side: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: shape.count)
        var stack = (0..<shape.count).filter { k in
            let x = k % side, y = k / side
            return (x == 0 || y == 0 || x == side - 1 || y == side - 1) && !shape[k]
        }
        for k in stack { outside[k] = true }
        while let k = stack.popLast() {
            let x = k % side, y = k / side
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < side && ny < side {
                let n = ny * side + nx
                if !shape[n] && !outside[n] {
                    outside[n] = true
                    stack.append(n)
                }
            }
        }
        return outside.map { !$0 }
    }

    /// How many cells in from its outline each cell of a shape is: 1 next to the outside, a step
    /// across counting 1 and diagonally √2 (near enough the true distance). Outside it, 0.
    static func insets(_ shape: [Bool], side: Int) -> [Double] {
        var inset = shape.map { $0 ? Double.infinity : 0 }
        let diagonal = 2.0.squareRoot()
        func at(_ x: Int, _ y: Int) -> Double { x < 0 || y < 0 || x >= side || y >= side ? 0 : inset[y * side + x] }
        for y in 0..<side {
            for x in 0..<side where inset[y * side + x] > 0 {
                let value = min(inset[y * side + x], at(x - 1, y) + 1, at(x, y - 1) + 1,
                                at(x - 1, y - 1) + diagonal, at(x + 1, y - 1) + diagonal)
                inset[y * side + x] = value
            }
        }
        for y in stride(from: side - 1, through: 0, by: -1) {
            for x in stride(from: side - 1, through: 0, by: -1) where inset[y * side + x] > 0 {
                let value = min(inset[y * side + x], at(x + 1, y) + 1, at(x, y + 1) + 1,
                                at(x + 1, y + 1) + diagonal, at(x - 1, y + 1) + diagonal)
                inset[y * side + x] = value
            }
        }
        return inset
    }

    /// A hidden cell's height. Seen from above, the line of sight runs from the spot under the
    /// camera through the cell; along it, between the nearest cells seen on either side, a straight
    /// line is the ray that grazed the food's top — the most that could be hidden there. The least
    /// is nothing (a burger's straight back hides only plate). A mound's back is close to the most,
    /// a cake's to the least: half way (`Tuning.hiddenShare`). A cell the photo shows the table at
    /// counts as nothing standing there.
    private static func filled(_ k: Int, food: [Double], hidden: [Bool], raster: Raster) -> Double {
        let spot = raster.centre(k)
        let distance = simd_length(spot)
        let direction = distance > 1e-6 ? spot / distance : SIMD2(1, 0)
        func walk(_ sign: Double) -> (Double, Double) {
            var t = raster.cell * 0.75
            while t < raster.half * 3 {
                guard let next = raster.index(spot + sign * t * direction) else { return (t, 0) }
                if !food[next].isNaN { return (t, food[next]) }
                if !hidden[next] { return (t, 0) }
                t += raster.cell * 0.75
            }
            return (t, 0)
        }
        let (ahead, far) = walk(1), (behind, near) = walk(-1)
        return Tuning.hiddenShare * (far * behind + near * ahead) / (ahead + behind)
    }

    /// To the nearest tenth: all a stored measurement needs.
    private static func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

// MARK: - The pieces

extension MealPhotoDepth {
    /// The map averaged down to about `Tuning.gridPoints`, smoothed (a 3 × 3 median: noise out,
    /// edges kept) and turned into points in the camera's frame — x right, y down, z ahead, metres.
    struct Grid {
        let width: Int
        let height: Int
        /// Map pixels per grid point, each way.
        let step: Int
        var points: [SIMD3<Double>?]

        init(_ map: DepthMap) {
            let step = max(1, Int((Double(map.width * map.height) / Double(Tuning.gridPoints)).squareRoot().rounded(.up)))
            let width = map.width / step, height = map.height / step
            // Each block's median: an average across a plate's edge would invent points in mid-air.
            var z = [Double](repeating: .nan, count: width * height)
            var block: [Double] = []
            block.reserveCapacity(step * step)
            for gy in 0..<height {
                for gx in 0..<width {
                    block.removeAll(keepingCapacity: true)
                    for y in gy * step..<(gy + 1) * step {
                        for x in gx * step..<(gx + 1) * step {
                            let value = map.depths[y * map.width + x]
                            if value.isFinite, value > 0.05, value < 5 { block.append(Double(value)) }
                        }
                    }
                    if block.count * 2 >= step * step {
                        block.sort()
                        z[gy * width + gx] = block[block.count / 2]
                    }
                }
            }
            var smooth = z
            var around: [Double] = []
            around.reserveCapacity(9)
            for gy in 0..<height {
                for gx in 0..<width {
                    around.removeAll(keepingCapacity: true)
                    for y in max(0, gy - 1)...min(height - 1, gy + 1) {
                        for x in max(0, gx - 1)...min(width - 1, gx + 1) where z[y * width + x].isFinite {
                            around.append(z[y * width + x])
                        }
                    }
                    if around.count >= 5 {
                        around.sort()
                        smooth[gy * width + gx] = around[around.count / 2]
                    }
                }
            }
            let centre = Double(step - 1) / 2
            points = smooth.indices.map { index in
                let depth = smooth[index]
                guard depth.isFinite else { return nil }
                let u = Double((index % width) * step) + centre, v = Double((index / width) * step) + centre
                return SIMD3((u - map.cx) * depth / map.fx, (v - map.cy) * depth / map.fy, depth)
            }
            self.width = width
            self.height = height
            self.step = step
        }

        /// The grid point a point in the camera's frame is seen at.
        func index(of point: SIMD3<Double>, map: DepthMap) -> Int? {
            guard point.z > 0.01 else { return nil }
            let u = map.fx * point.x / point.z + map.cx, v = map.fy * point.y / point.z + map.cy
            let centre = Double(step - 1) / 2
            let gx = Int(((u - centre) / Double(step)).rounded()), gy = Int(((v - centre) / Double(step)).rounded())
            guard gx >= 0, gx < width, gy >= 0, gy < height else { return nil }
            return gy * width + gx
        }
    }

    /// A plane in the camera's frame, facing it: `height` is how far a point stands off it towards
    /// the camera.
    struct Plane {
        var normal: SIMD3<Double>
        var offset: Double
        /// The spread of the points it was fitted to.
        var rms = 0.0

        func height(_ point: SIMD3<Double>) -> Double { simd_dot(normal, point) + offset }

        /// Two directions along the plane. With them, (0, 0) is the spot right under the camera.
        var axes: (SIMD3<Double>, SIMD3<Double>) {
            var first = SIMD3<Double>(1, 0, 0) - normal.x * normal
            if simd_length(first) < 0.1 { first = SIMD3<Double>(0, 1, 0) - normal.y * normal }
            first = simd_normalize(first)
            return (first, simd_cross(normal, first))
        }

        /// Where a point lies on the plane, seen from straight above.
        func flat(_ point: SIMD3<Double>, _ axes: (SIMD3<Double>, SIMD3<Double>)) -> SIMD2<Double> {
            SIMD2(simd_dot(axes.0, point), simd_dot(axes.1, point))
        }

        /// The point at a spot on the plane, raised by `height`.
        func point(_ spot: SIMD2<Double>, height: Double, _ axes: (SIMD3<Double>, SIMD3<Double>)) -> SIMD3<Double> {
            (height - offset) * normal + spot.x * axes.0 + spot.y * axes.1
        }

        /// Through three points, facing the camera; nil when they're in a line.
        init?(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 1e-12 else { return nil }
            self.init(normal: cross / length, offset: -simd_dot(cross / length, a))
        }

        init(normal: SIMD3<Double>, offset: Double, rms: Double = 0) {
            // Facing the camera, which is at the origin: its height above the plane is positive.
            let flip = offset < 0 ? -1.0 : 1.0
            self.normal = normal * flip
            self.offset = offset * flip
            self.rms = rms
        }

        /// Fitted to `points` by least squares, starting from this plane (its tilt and height
        /// corrected in its own frame, which stays well conditioned however the camera is held).
        func refined(_ points: [SIMD3<Double>]) -> Plane? {
            guard points.count >= 3 else { return nil }
            let (e1, e2) = axes
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            var v = [0.0, 0.0, 0.0]
            for point in points {
                let row = [simd_dot(e1, point), simd_dot(e2, point), 1]
                let h = height(point)
                for i in 0..<3 {
                    v[i] += row[i] * h
                    for j in 0..<3 { m[i][j] += row[i] * row[j] }
                }
            }
            guard let s = solve3(m, v) else { return nil }
            let raw = normal - s[0] * e1 - s[1] * e2
            let length = simd_length(raw)
            guard length > 1e-9 else { return nil }
            var plane = Plane(normal: raw / length, offset: (offset - s[2]) / length)
            plane.rms = (points.reduce(0) { $0 + pow(plane.height($1), 2) } / Double(points.count)).squareRoot()
            return plane
        }
    }

    /// How far a point at `depth` may be off a plane and still be on it.
    private static func tolerance(_ depth: Double) -> Double { Tuning.tableTolerance * max(1, depth / 0.5) }

    /// The plane most of `points` lie on, facing the camera: RANSAC, each candidate scored by how
    /// closely the points sit on it (squared distance, capped — MSAC) rather than by how many are
    /// near it. A plane tilted to catch the table at one side and a plate's floor a few millimetres
    /// up at the other holds as many points loosely, but none of them exactly.
    static func dominantPlane(_ points: [SIMD3<Double>], random: inout SplitMix) -> Plane? {
        guard points.count >= 30 else { return nil }
        let every = max(1, points.count / Tuning.planeSample)
        let sample = stride(from: 0, to: points.count, by: every).map { points[$0] }
        var best: (plane: Plane, cost: Double)?
        for _ in 0..<Tuning.planeRounds {
            let a = sample[Int.random(in: 0..<sample.count, using: &random)]
            let b = sample[Int.random(in: 0..<sample.count, using: &random)]
            let c = sample[Int.random(in: 0..<sample.count, using: &random)]
            // Seen from at least 20° above it: a table, not a wall or the side of a glass.
            guard let plane = Plane(a, b, c), -plane.normal.z > 0.34 else { continue }
            let cost = sample.reduce(0.0) { cost, point in
                cost + min(pow(plane.height(point), 2), pow(tolerance(point.z), 2))
            }
            if cost < best?.cost ?? .infinity { best = (plane, cost) }
        }
        guard var plane = best?.plane else { return nil }
        var inliers = points.filter { abs(plane.height($0)) < tolerance($0.z) }
        for _ in 0..<3 {
            guard let refined = plane.refined(inliers) else { break }
            plane = refined
            let band = max(0.002, 2.5 * plane.rms)
            inliers = points.filter { abs(plane.height($0)) < min(band, tolerance($0.z)) }
        }
        guard -plane.normal.z > 0.34, inliers.count * 5 >= points.count else { return nil }
        return plane.refined(inliers) ?? plane
    }

    /// The table: the dominant plane — unless a parallel plane a little below it holds plenty of
    /// points, in which case the dominant one was a plate's floor filling a close-up.
    static func supportPlane(_ points: [SIMD3<Double>], random: inout SplitMix) -> Plane? {
        guard let dominant = dominantPlane(points, random: &random) else { return nil }
        let gap = min(0.03, max(0.006, 3 * dominant.rms))
        let below = points.filter { (-0.05 ..< -gap).contains(dominant.height($0)) }
        guard below.count >= max(150, points.count / 25),
              let lower = dominantPlane(below, random: &random),
              simd_dot(lower.normal, dominant.normal) > cos(15 * Double.pi / 180) else { return dominant }
        let held = below.filter { abs(lower.height($0)) < max(0.004, 2.5 * lower.rms) }.count
        return held * 2 >= below.count ? lower : dominant
    }

    /// The region standing on the table nearest the middle of the photo, with its holes filled
    /// (a plate's floor can sit below the threshold; a missing reading is still the plate).
    struct Region {
        var mask: [Bool]
        /// Its outline: cells next to one outside it, not counting the photo's own edge.
        var edge: [Int]
        var touchesFrame: Bool
    }

    static func standingRegion(_ heights: [Double?], width: Int, height: Int, above stand: Double) -> Region? {
        let count = width * height
        let up = heights.map { h in h.map { $0 > stand && $0 < 0.3 } ?? false }
        var label = [Int32](repeating: -1, count: count)
        let minimum = max(30, count / 300)
        let middle = SIMD2(Double(width - 1) / 2, Double(height - 1) / 2)
        var best: (label: Int32, distance: Double, size: Int)?
        var stack: [Int] = []
        var next: Int32 = 0
        func neighbours(_ i: Int) -> [Int] {
            let x = i % width, y = i / width
            var out: [Int] = []
            if x > 0 { out.append(i - 1) }
            if x < width - 1 { out.append(i + 1) }
            if y > 0 { out.append(i - width) }
            if y < height - 1 { out.append(i + width) }
            return out
        }
        for start in 0..<count where up[start] && label[start] < 0 {
            label[start] = next
            stack = [start]
            var size = 0
            var nearest = Double.infinity
            while let i = stack.popLast() {
                size += 1
                nearest = min(nearest, simd_distance(SIMD2(Double(i % width), Double(i / width)), middle))
                for n in neighbours(i) where up[n] && label[n] < 0 {
                    label[n] = next
                    stack.append(n)
                }
            }
            if size >= minimum, nearest < best?.distance ?? .infinity
                || (nearest == best?.distance && size > best?.size ?? 0) {
                best = (next, nearest, size)
            }
            next += 1
        }
        guard let best else { return nil }
        var mask = label.map { $0 == best.label }
        // Holes: whatever can't reach the photo's edge without crossing the region.
        var outside = [Bool](repeating: false, count: count)
        stack = (0..<count).filter { i in
            let x = i % width, y = i / width
            return (x == 0 || y == 0 || x == width - 1 || y == height - 1) && !mask[i]
        }
        for i in stack { outside[i] = true }
        while let i = stack.popLast() {
            for n in neighbours(i) where !mask[n] && !outside[n] {
                outside[n] = true
                stack.append(n)
            }
        }
        var touchesFrame = false
        var edge: [Int] = []
        for i in 0..<count {
            if !mask[i] && !outside[i] { mask[i] = true }
        }
        for i in 0..<count where mask[i] {
            let x = i % width, y = i / width
            if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                touchesFrame = true
                continue
            }
            if neighbours(i).contains(where: { !mask[$0] }) { edge.append(i) }
        }
        return Region(mask: mask, edge: edge, touchesFrame: touchesFrame)
    }

    /// The region's outline seen from above: a circle when it's round (a plate, a bowl), else its
    /// middle and its longest extent.
    struct Outline {
        var centre: SIMD2<Double>
        var radius: Double
        var round: Bool
        var across: Double { radius * 2 }

        init?(edge: [SIMD2<Double>], inside: [SIMD2<Double>]) {
            if let circle = Self.circle(edge), circle.spread / circle.radius < Tuning.roundness, circle.sides >= 7 {
                centre = circle.centre
                radius = circle.radius
                round = true
                return
            }
            // Not round: along its main axis, ignoring the odd stray point at either end.
            guard inside.count >= 10 else { return nil }
            let mean = inside.reduce(SIMD2<Double>.zero, +) / Double(inside.count)
            var xx = 0.0, xy = 0.0, yy = 0.0
            for p in inside {
                let d = p - mean
                xx += d.x * d.x
                xy += d.x * d.y
                yy += d.y * d.y
            }
            let angle = 0.5 * atan2(2 * xy, xx - yy)
            let along = SIMD2(cos(angle), sin(angle)), across = SIMD2(-sin(angle), cos(angle))
            // Its ends from the outline, which has plenty of points at them (the inside's points
            // crowd towards the camera).
            let ends = edge.count >= 20 ? edge : inside
            let a = ends.map { simd_dot($0 - mean, along) }, b = ends.map { simd_dot($0 - mean, across) }
            let (a0, a1) = (percentile(a, 0.01), percentile(a, 0.99)), (b0, b1) = (percentile(b, 0.01), percentile(b, 0.99))
            centre = mean + along * (a0 + a1) / 2 + across * (b0 + b1) / 2
            radius = (a1 - a0) / 2
            round = false
            guard radius > 0 else { return nil }
        }

        /// A least-squares circle through the outline, refitted twice without the points furthest
        /// off it. `spread`: how far the kept points sit from it; `sides`: of 12 directions around
        /// the centre, how many have outline in them.
        static func circle(_ points: [SIMD2<Double>]) -> (centre: SIMD2<Double>, radius: Double, spread: Double, sides: Int)? {
            var kept = points
            var fit: (SIMD2<Double>, Double)?
            for _ in 0..<3 {
                    guard kept.count >= 12, let next = kasa(kept) else { return nil }
                fit = next
                let off = kept.map { abs(simd_distance($0, next.0) - next.1) }
                let limit = max(0.003, 2.5 * percentile(off, 0.5))
                let closer = kept.indices.filter { off[$0] <= limit }.map { kept[$0] }
                if closer.count == kept.count { break }
                kept = closer
            }
            guard let fit, kept.count >= 12 else { return nil }
            let (centre, radius) = fit
            let spread = (kept.reduce(0) { $0 + pow(simd_distance($1, centre) - radius, 2) } / Double(kept.count)).squareRoot()
            var sides = Set<Int>()
            for p in kept {
                let angle = atan2(p.y - centre.y, p.x - centre.x) + .pi
                sides.insert(min(11, Int(angle / (2 * .pi) * 12)))
            }
            return (centre, radius, spread, sides.count)
        }

        /// Kåsa's fit: x² + y² + Dx + Ey + F = 0 by least squares, about the points' mean.
        private static func kasa(_ points: [SIMD2<Double>]) -> (SIMD2<Double>, Double)? {
            let mean = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            var v = [0.0, 0.0, 0.0]
            for p in points {
                let d = p - mean
                let row = [d.x, d.y, 1.0], z = d.x * d.x + d.y * d.y
                for i in 0..<3 {
                    v[i] -= row[i] * z
                    for j in 0..<3 { m[i][j] += row[i] * row[j] }
                }
            }
            guard let s = solve3(m, v) else { return nil }
            let offset = SIMD2(-s[0] / 2, -s[1] / 2)
            let squared = simd_length_squared(offset) - s[2]
            guard squared > 0 else { return nil }
            return (mean + offset, squared.squareRoot())
        }
    }

    /// A square grid over the table around the region, `cell` metres a side.
    struct Raster {
        let origin: SIMD2<Double>
        let half: Double
        let cell: Double
        let side: Int
        var count: Int { side * side }

        init(centre: SIMD2<Double>, half: Double, cell: Double) {
            self.half = half
            self.cell = cell
            side = Int((2 * half / cell).rounded(.up))
            origin = centre - SIMD2(half, half)
        }

        func index(_ spot: SIMD2<Double>) -> Int? {
            let x = Int(((spot.x - origin.x) / cell).rounded(.down)), y = Int(((spot.y - origin.y) / cell).rounded(.down))
            guard x >= 0, x < side, y >= 0, y < side else { return nil }
            return y * side + x
        }

        func centre(_ k: Int) -> SIMD2<Double> {
            origin + SIMD2(Double(k % side) + 0.5, Double(k / side) + 0.5) * cell
        }
    }

    /// The same random numbers every time, so a photo always measures the same.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Solves a 3 × 3 system by Cramer's rule; nil when it has no single answer.
    static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let whole = det(m)
        guard whole.isNormal else { return nil }
        let answer = (0..<3).map { column -> Double in
            var a = m
            for row in 0..<3 { a[row][column] = v[row] }
            return det(a) / whole
        }
        return answer.allSatisfy(\.isFinite) ? answer : nil
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    static func median(_ values: [Double]) -> Double? { values.isEmpty ? nil : percentile(values, 0.5) }
}

// MARK: - What the estimate and the review are told

extension MealPhotoDepth {
    /// One line per measured photo, for the model: "the plate is about 26 cm across; the food on it
    /// is about 540 ml and stands up to 4 cm". Two photos of the same plate say it once.
    static func lines(_ depths: [PhotoDepth]) -> [String] {
        var seen = Set<String>()
        return depths.filter(\.isUsable).map(line).filter { seen.insert($0).inserted }
    }

    static func line(_ depth: PhotoDepth) -> String {
        let across = cm(depth.acrossCm)
        let height = depth.heightCm.map(cm)
        switch depth.kind {
        case .plate:
            guard let food = depth.foodMl.map(ml) else { return "the plate is about \(across) cm across" }
            return "the plate is about \(across) cm across; the food on it is about \(food) ml"
                + (height.map { " and stands up to \($0) cm" } ?? "")
        case .bowl:
            return "the bowl is about \(across) cm across"
        case .unknown:
            guard let food = depth.foodMl.map(ml) else { return "the food is about \(across) cm across" }
            return "the food is about \(across) cm across and about \(food) ml" + (height.map { ", standing up to \($0) cm" } ?? "")
        }
    }

    /// The review's note under a meal: "Measured: plate 26 cm · food ≈ 540 ml". Nil with nothing measured.
    static func caption(_ depths: [PhotoDepth]) -> String? {
        var seen = Set<String>()
        let parts = depths.filter(\.isUsable).map { depth -> String in
            let across = cm(depth.acrossCm)
            let food = depth.foodMl.map { " \u{00B7} food \u{2248} \(ml($0)) ml" } ?? ""
            switch depth.kind {
            case .plate: return "plate \(across) cm" + food
            case .bowl: return "bowl \(across) cm"
            case .unknown: return "\(across) cm across" + food
            }
        }.filter { seen.insert($0).inserted }
        guard !parts.isEmpty else { return nil }
        return "Measured: " + parts.prefix(2).joined(separator: " \u{00B7} ")
    }

    /// Whole centimetres, at least 1.
    private static func cm(_ value: Double) -> Int { max(1, Int(value.rounded())) }
    /// The nearest 10 ml, at least 10.
    private static func ml(_ value: Double) -> Int { max(10, Int((value / 10).rounded()) * 10) }
}
