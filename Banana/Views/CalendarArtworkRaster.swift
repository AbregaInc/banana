import SwiftUI

/// Snapshot every environment input used by calendar text/symbol/color rendering. The native
/// surface must construct a fresh request when these values or the event's paint inputs change.
@available(macOS 14.0, iOS 17.0, *)
struct CalendarArtworkRasterRequest: Equatable, Hashable {
    struct RGBA: Equatable {
        let red: Float, green: Float, blue: Float, opacity: Float
        init(_ color: Color, environment: EnvironmentValues) {
            let value = color.resolve(in: environment)
            red = value.red; green = value.green; blue = value.blue; opacity = value.opacity
        }
    }
    let identityPaint: CalendarEventPaint
    let width: CGFloat
    let height: CGFloat
    let paintHeight: CGFloat
    let scale: CGFloat
    let desktop: Bool
    let showsIcon: Bool
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let direction: LayoutDirection
    let locale: Locale
    let timeZone: TimeZone
    let calendar: Calendar
    let typeSize: DynamicTypeSize
    let legibility: LegibilityWeight?
    let differentiateWithoutColor: Bool
    let reduceTransparency: Bool
    let enabled: Bool
    let redaction: RedactionReasons
    let luminanceReduced: Bool
    let symbolVariants: SymbolVariants
    let imageScale: Image.Scale
    let textAlignment: TextAlignment
    let truncation: Text.TruncationMode
    let lineSpacing: CGFloat
    let allowsTightening: Bool
    let minimumScale: CGFloat
    let textCase: Text.Case?
    // Dynamic platform colors can change while the Color object's identity stays constant.
    let resolvedColors: [RGBA]

    init(paint: CalendarEventPaint, size: CGSize, desktop: Bool, showsIcon: Bool,
         environment: EnvironmentValues, usesResolvedColorIdentity: Bool = true, paintHeight: CGFloat? = nil) {
        var identity = paint
        if usesResolvedColorIdentity {
            // CalendarColor creates new dynamic platform color objects for the same palette.
            // Their object equality differs even when their resolved pixels are identical.
            // Colors/count remain fully represented by resolvedColors below.
            identity.tint = .clear; identity.ribbons = []
        }
        identityPaint = identity; width = size.width; height = size.height
        self.paintHeight = paintHeight ?? size.height
        scale = environment.displayScale; self.desktop = desktop; self.showsIcon = showsIcon
        colorScheme = environment.colorScheme; contrast = environment.colorSchemeContrast
        direction = environment.layoutDirection
        // Freeze autoupdating Foundation values. Keeping .autoupdatingCurrent in an old key
        // would let its meaning change in place after a system locale/timezone change.
        locale = Locale(identifier: environment.locale.identifier)
        timeZone = TimeZone(identifier: environment.timeZone.identifier) ?? environment.timeZone
        var fixedCalendar = Calendar(identifier: environment.calendar.identifier)
        fixedCalendar.locale = environment.calendar.locale.map { Locale(identifier: $0.identifier) }
        fixedCalendar.timeZone = TimeZone(identifier: environment.calendar.timeZone.identifier)
            ?? environment.calendar.timeZone
        fixedCalendar.firstWeekday = environment.calendar.firstWeekday
        fixedCalendar.minimumDaysInFirstWeek = environment.calendar.minimumDaysInFirstWeek
        calendar = fixedCalendar
        typeSize = environment.dynamicTypeSize; legibility = environment.legibilityWeight
        differentiateWithoutColor = environment.accessibilityDifferentiateWithoutColor
        reduceTransparency = environment.accessibilityReduceTransparency
        enabled = environment.isEnabled
        redaction = environment.redactionReasons; luminanceReduced = environment.isLuminanceReduced
        symbolVariants = environment.symbolVariants; imageScale = environment.imageScale
        textAlignment = environment.multilineTextAlignment; truncation = environment.truncationMode
        lineSpacing = environment.lineSpacing; allowsTightening = environment.allowsTightening
        minimumScale = environment.minimumScaleFactor; textCase = environment.textCase
        resolvedColors = ([paint.tint] + paint.ribbons + [.primary, .secondary, DS.Palette.travel, DS.Palette.accent])
            .map { RGBA($0, environment: environment) }
    }

    func hash(into hasher: inout Hasher) {
        // Full synthesized equality remains authoritative, including all colors and environment
        // values. A small hash avoids walking long title/location strings more than necessary;
        // collisions cannot reuse another request's pixels.
        hasher.combine(identityPaint.title); hasher.combine(identityPaint.start)
        hasher.combine(width); hasher.combine(height); hasher.combine(scale)
        hasher.combine(desktop); hasher.combine(showsIcon); hasher.combine(paintHeight)
    }
}

/// Apple-rendered immutable event sprites for the native calendar surface. ImageRenderer is
/// main-actor isolated: callers must prepare outside input handlers, never dispatch this work
/// to an arbitrary worker. Composition of the returned immutable images can run separately.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class CalendarArtworkRasterCache {
    enum Rendering { case coreGraphics, cgImage, nativeCoreText }
    let rendering: Rendering
    let usesResolvedColorIdentity: Bool
    enum Failure: Error { case invalidDimensions, exceedsEntryBudget, unsupportedEnvironment, unavailable }
    struct Statistics {
        var hits = 0
        var renders = 0
        var evictions = 0
        var rejected = 0
        var renderAttempts = 0
        var renderSamplesMS: [Double] = []
        var maximumRenderMS: Double = 0
        var droppedRenderSamples = 0
    }
    private struct Entry {
        let image: CGImage
        let bytes: Int
        var age: UInt64
    }
    // Cache limits, not device memory budgets. Surface-owned active images and compositor
    // retention must be measured and bounded separately by the consuming viewport.
    let byteLimit: Int
    let entryLimit: Int
    let maximumEntryBytes: Int
    let recordRenderTimings: Bool
    let timingSampleLimit: Int
    private(set) var retainedBytes = 0
    private(set) var statistics = Statistics()
    var count: Int { entries.count }
    private var entries: [CalendarArtworkRasterRequest: Entry] = [:]
    private var age: UInt64 = 0

    init(byteLimit: Int = 32 * 1024 * 1024, entryLimit: Int = 256,
         maximumEntryBytes: Int = 2 * 1024 * 1024, rendering: Rendering = .coreGraphics,
         usesResolvedColorIdentity: Bool = true, recordRenderTimings: Bool = false,
         timingSampleLimit: Int = 4096) {
        precondition(timingSampleLimit >= 0)
        precondition(byteLimit >= 0 && entryLimit >= 0 && maximumEntryBytes > 0)
        self.byteLimit = byteLimit; self.entryLimit = entryLimit
        self.maximumEntryBytes = maximumEntryBytes; self.rendering = rendering
        self.usesResolvedColorIdentity = usesResolvedColorIdentity
        self.recordRenderTimings = recordRenderTimings; self.timingSampleLimit = timingSampleLimit
        if recordRenderTimings { statistics.renderSamplesMS.reserveCapacity(timingSampleLimit) }
    }

    /// Lookup only: safe for preparation's fast path; never invokes ImageRenderer.
    func cachedImage(paint: CalendarEventPaint, size: CGSize, desktop: Bool, showsIcon: Bool,
                     environment: EnvironmentValues, paintHeight: CGFloat? = nil) -> CGImage? {
        guard environment.symbolRenderingMode == nil else { return nil }
        let request = CalendarArtworkRasterRequest(paint: paint, size: size, desktop: desktop,
            showsIcon: showsIcon, environment: environment, usesResolvedColorIdentity: usesResolvedColorIdentity, paintHeight: paintHeight)
        return lookup(request)
    }

    private func lookup(_ request: CalendarArtworkRasterRequest) -> CGImage? {
        age &+= 1
        guard var entry = entries[request] else { return nil }
        entry.age = age; entries[request] = entry
        statistics.hits += 1
        return entry.image
    }

    func image(paint: CalendarEventPaint, size: CGSize, desktop: Bool, showsIcon: Bool,
               environment: EnvironmentValues, paintHeight: CGFloat? = nil) throws -> CGImage {
        // SymbolRenderingMode is opaque and not Equatable in the public SDK. Until the
        // surface has a distinct style identity for it, use its live fallback instead of
        // accepting a cache key that could confuse two explicit symbol rendering modes.
        guard environment.symbolRenderingMode == nil else {
            statistics.rejected += 1; throw Failure.unsupportedEnvironment
        }
        let request = CalendarArtworkRasterRequest(paint: paint, size: size, desktop: desktop,
            showsIcon: showsIcon, environment: environment, usesResolvedColorIdentity: usesResolvedColorIdentity, paintHeight: paintHeight)
        if let image = lookup(request) { return image }
        guard request.width.isFinite, request.height.isFinite, request.scale.isFinite,
              request.width > 0, request.height > 0, request.scale > 0,
              request.paintHeight.isFinite, request.paintHeight > 0 else {
            statistics.rejected += 1; throw Failure.invalidDimensions
        }
        let pixelsWide = ceil(request.width * request.scale)
        let pixelsHigh = ceil(request.height * request.scale)
        // Check before conversion/allocation, including multiplication overflow. Oversized
        // blocks require the surface's live/vector fallback; they must never be silently hidden.
        guard pixelsWide.isFinite, pixelsHigh.isFinite,
              pixelsWide * pixelsHigh <= CGFloat(maximumEntryBytes / 4) else {
            statistics.rejected += 1; throw Failure.exceedsEntryBudget
        }
        let started = recordRenderTimings ? DispatchTime.now().uptimeNanoseconds : 0
        if recordRenderTimings { statistics.renderAttempts += 1 }
        defer {
            if recordRenderTimings {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                statistics.maximumRenderMS = max(statistics.maximumRenderMS, elapsed)
                if statistics.renderSamplesMS.count < timingSampleLimit {
                    statistics.renderSamplesMS.append(elapsed)
                } else { statistics.droppedRenderSamples += 1 }
            }
        }
        let image = try Self.render(request, paint: paint, environment: environment, rendering: rendering,
            maximumBytes: maximumEntryBytes)
        statistics.renders += 1
        let bytes = image.bytesPerRow * image.height
        guard bytes <= maximumEntryBytes else {
            statistics.rejected += 1; throw Failure.exceedsEntryBudget
        }
        if entryLimit > 0 && bytes <= byteLimit {
            while !entries.isEmpty && (entries.count >= entryLimit || retainedBytes > byteLimit - bytes) {
                let oldest = entries.min { $0.value.age < $1.value.age }!.key
                retainedBytes -= entries.removeValue(forKey: oldest)!.bytes
                statistics.evictions += 1
            }
            entries[request] = Entry(image: image, bytes: bytes, age: age)
            retainedBytes += bytes
        }
        return image
    }

    /// Bounded diagnostic capture. Overflow is explicit; a truncated report cannot be accepted
    /// as a complete latency distribution. The maximum continues to include every attempt.
    func preparationReport() -> [String: Any] {
        let backend: String
        switch rendering {
        case .coreGraphics: backend = "swiftui-core-graphics"
        case .cgImage: backend = "swiftui-cgimage"
        case .nativeCoreText: backend = "native-core-text"
        }
        return ["backend": backend, "recordingEnabled": recordRenderTimings, "renders": statistics.renders,
         "hits": statistics.hits, "evictions": statistics.evictions, "rejected": statistics.rejected,
         "renderAttempts": statistics.renderAttempts, "samplesMS": statistics.renderSamplesMS,
         "maximumMS": statistics.maximumRenderMS, "droppedSamples": statistics.droppedRenderSamples,
         "retainedPixelBytes": retainedBytes, "entryCount": count, "pixelByteLimit": byteLimit,
         "scope": "Main-actor cache-miss preparation after key validation, including rasterization and cache insertion. Not frames or input-to-visible latency."]
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
        retainedBytes = 0
    }

    private static func render(_ request: CalendarArtworkRasterRequest, paint: CalendarEventPaint,
                               environment: EnvironmentValues, rendering: Rendering, maximumBytes: Int) throws -> CGImage {
        if case .nativeCoreText = rendering {
            return try CalendarNativeEventRaster.render(CalendarNativeEventAdapter.request(
                paint: paint, size: CGSize(width: request.width, height: request.height),
                paintHeight: request.paintHeight, desktop: request.desktop,
                showsIcon: request.showsIcon, environment: environment), maximumBytes: maximumBytes)
        }
        // Apply the actual inherited environment, including read-only system accessibility
        // values. It is transient: neither the cache key nor the returned image retains it.
        let content = CalendarEventArtwork(paint: paint, height: request.paintHeight,
            layout: request.desktop ? .desktop : .mobile, showsIcon: request.showsIcon)
            .frame(width: request.width, height: request.height)
            .environment(\.self, environment)
        let renderer = ImageRenderer(content: content)
        renderer.scale = request.scale
        if case .cgImage = rendering {
            guard let image = renderer.cgImage else { throw Failure.unavailable }
            return image
        } else {
            var result: CGImage?
            renderer.render(rasterizationScale: request.scale) { size, draw in
                guard let context = CGContext(data: nil,
                    width: Int(ceil(size.width * request.scale)),
                    height: Int(ceil(size.height * request.scale)), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.scaleBy(x: request.scale, y: request.scale)
                draw(context)
                result = context.makeImage()
            }
            guard let result else { throw Failure.unavailable }
            return result
        }
    }
}
