import Foundation
import CoreGraphics
import QuartzCore
import Metal
import CoreVideo

@_silgen_name("calendar_live_prepare") private func prepareLive(_ json: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("calendar_skia_destroy") private func releaseLive(_ page: UnsafeMutableRawPointer)
@_silgen_name("calendar_skia_picture_stat") private func pictureStat(_ page: UnsafeMutableRawPointer, _ index: Int32) -> Double
@_silgen_name("calendar_live_renderer") private func createRenderer(_ device: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
@_silgen_name("calendar_live_raster_page") private func rasterPage(_ renderer: UnsafeMutableRawPointer, _ page: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
typealias PresentCallback = @convention(c) (UnsafeMutableRawPointer?, Double, Double, Double, Int32) -> Void
typealias GPUCallback = @convention(c) (UnsafeMutableRawPointer?, Double, Int32) -> Void
@_silgen_name("calendar_live_draw") private func drawLive(_ renderer: UnsafeMutableRawPointer, _ page: UnsafeMutableRawPointer,
    _ drawable: UnsafeMutableRawPointer, _ offset: Double, _ token: UnsafeMutableRawPointer, _ callback: PresentCallback,
    _ gpuToken: UnsafeMutableRawPointer, _ gpuCallback: GPUCallback) -> Int32

final class LiveLog: @unchecked Sendable {
    static let shared = LiveLog()
    let queue = DispatchQueue(label: "calendar.live.evidence", qos: .utility)
    let url: URL
    private let file: FileHandle
    private var memoryTimer: DispatchSourceTimer?
    private init() {
        let config = CalendarFixtureConfiguration()
        let defaultURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("calendar-live-\(Int(Date().timeIntervalSince1970)).jsonl")
        url = URL(fileURLWithPath: config.value("--log", defaultURL.path))
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(!FileManager.default.fileExists(atPath: url.path), "Never overwrite evidence")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try! FileHandle(forWritingTo: url)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.add("memory", ["peakRSS": peakResidentBytes(), "footprint": physicalFootprintBytes(),
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
        }
        memoryTimer = timer; timer.resume()
    }
    func add(_ kind: String, _ values: [String: Any] = [:]) {
        let row = values.merging(["kind": kind, "time": CACurrentMediaTime()]) { a, _ in a }
        queue.async { [self] in
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                try? file.write(contentsOf: data); try? file.write(contentsOf: Data([10]))
            }
        }
    }
}
final class LivePage: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let date: Date
    let width: Int
    let scale: Int
    let events: Int
    let bytes: Double
    let surfaces: [CVPixelBuffer]
    init(_ pointer: UnsafeMutableRawPointer, date: Date, width: Int, scale: Int, events: Int, surfaces: [CVPixelBuffer] = []) {
        self.pointer = pointer; self.date = date; self.width = width; self.scale = scale; self.events = events
        bytes = pictureStat(pointer, 0)
        self.surfaces = surfaces
    }
    deinit { releaseLive(pointer) }
}

private final class FrameToken {
    let page: LivePage
    let requested: Double, input: Double, offset: Double
    let generation: Int
    let inputKind: String
    let releaseOnGPUCompletion: Bool
    let completion: () -> Void
    init(page: LivePage, requested: Double, input: Double, inputKind: String, offset: Double, generation: Int,
         releaseOnGPUCompletion: Bool, completion: @escaping () -> Void) {
        self.page = page; self.requested = requested; self.input = input; self.offset = offset
        self.generation = generation; self.completion = completion
        self.inputKind = inputKind
        self.releaseOnGPUCompletion = releaseOnGPUCompletion
    }
    func finish(_ began: Double, _ encoded: Double, _ presented: Double, _ ok: Int32) {
        LiveLog.shared.add("frame", ["generation": generation, "date": page.date.timeIntervalSince1970,
            "offset": offset, "requested": requested, "input": input, "began": began, "encoded": encoded,
            "presented": presented, "ok": ok, "width": page.width, "scale": page.scale, "inputKind": inputKind,
            "scope": "UI scroll/button callback to CAMetalDrawable presentedTime; not hardware input-to-photon"])
        if !releaseOnGPUCompletion { completion() }
    }
    func gpuFinished(_ time: Double, _ ok: Int32) {
        LiveLog.shared.add("gpuCompleted", ["requested": requested, "completed": time, "ok": ok])
        if releaseOnGPUCompletion { completion() }
    }
}
private let onPresented: PresentCallback = { token, began, encoded, presented, ok in
    guard let token else { return }
    Unmanaged<FrameToken>.fromOpaque(token).takeRetainedValue().finish(began, encoded, presented, ok)
}
private let onGPUCompleted: GPUCallback = { token, time, ok in
    guard let token else { return }
    Unmanaged<FrameToken>.fromOpaque(token).takeRetainedValue().gpuFinished(time, ok)
}

private final class LiveGPUState: @unchecked Sendable { var context: UnsafeMutableRawPointer? }

@MainActor final class LivePresentation: NSObject, CAMetalDisplayLinkDelegate {
    private let queue = DispatchQueue(label: "calendar.live.metal", qos: .userInteractive)
    private let gpu = LiveGPUState()
    private var pending = 0
    private var requestedAgain = false
    private let maxInFlight = Int(CalendarFixtureConfiguration().value("--max-inflight", "2"))!
    private let useDisplayLink = CalendarFixtureConfiguration().args.contains("--metal-display-link") ||
        (Bundle.main.object(forInfoDictionaryKey: "CalendarMetalUseDisplayLink") as? Bool == true)
    private var displayLink: CAMetalDisplayLink?
    private let releaseOnGPUCompletion = CalendarFixtureConfiguration().args.contains("--release-on-gpu-completion")
    private let nativeSurfaces = CalendarFixtureConfiguration().args.contains("--native-surfaces")
    var current: LivePage?
    var offset = 0.0
    var generation = 0
    var inputTimestamp = 0.0
    var inputKind = "none"
    var layer: CAMetalLayer? {
        didSet {
            guard useDisplayLink, let layer else { return }
            displayLink?.invalidate()
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameLatency = 1
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }
    var didPresent: (() -> Void)?
    init(device: MTLDevice) {
        super.init()
        precondition((1...2).contains(maxInFlight))
        LiveLog.shared.add("policy", ["maxInFlight": maxInFlight, "metalDisplayLink": useDisplayLink,
            "releaseOnGPUCompletion": releaseOnGPUCompletion, "nativeSurfaces": nativeSurfaces,
            "memoText": CalendarFixtureConfiguration().args.contains("--memo-text")])
        if !nativeSurfaces {
            queue.async { [gpu] in gpu.context = createRenderer(Unmanaged.passUnretained(device as AnyObject).toOpaque()) }
        }
    }
    func request() {
        if useDisplayLink {
            requestedAgain = true; displayLink?.isPaused = false
            return
        }
        submit()
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard requestedAgain else {
            if pending == 0 { link.isPaused = true }
            return
        }
        guard pending < maxInFlight else { LiveLog.shared.add("coalesced"); return }
        requestedAgain = false
        LiveLog.shared.add("displayUpdate", ["target": update.targetTimestamp, "presentationTarget": update.targetPresentationTimestamp])
        submit(drawable: update.drawable)
    }
    private func submit(drawable suppliedDrawable: CAMetalDrawable? = nil) {
        guard let page = current, let layer else { return }
        if pending >= maxInFlight { requestedAgain = true; LiveLog.shared.add("coalesced"); return }
        pending += 1
        let requested = CACurrentMediaTime(), offset = offset, generation = generation, input = inputTimestamp
        inputTimestamp = 0
        let token = FrameToken(page: page, requested: requested, input: input, inputKind: inputKind, offset: offset, generation: generation,
                              releaseOnGPUCompletion: releaseOnGPUCompletion) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pending -= 1; self.didPresent?()
                if self.requestedAgain && !self.useDisplayLink { self.requestedAgain = false; self.request() }
            }
        }
        queue.async { [gpu] in
            guard let context = gpu.context, let drawable = suppliedDrawable ?? layer.nextDrawable() else {
                token.finish(requested, CACurrentMediaTime(), 0, 0); token.gpuFinished(CACurrentMediaTime(), 0); return
            }
            let opaque = Unmanaged.passRetained(token).toOpaque()
            let gpuOpaque = Unmanaged.passRetained(token).toOpaque()
            if drawLive(context, page.pointer, Unmanaged.passUnretained(drawable as AnyObject).toOpaque(), offset, opaque, onPresented, gpuOpaque, onGPUCompleted) == 0 {
                Unmanaged<FrameToken>.fromOpaque(opaque).takeRetainedValue().finish(requested, CACurrentMediaTime(), 0, 0)
                Unmanaged<FrameToken>.fromOpaque(gpuOpaque).takeRetainedValue().gpuFinished(CACurrentMediaTime(), 0)
            }
        }
    }
}

@MainActor final class LiveModel {
    let config = CalendarFixtureConfiguration(args: ProcessInfo.processInfo.arguments + ["--fixture", "varied-v1", "--mode", "week"])
    let store: FixtureStore
    let nativeSurfaces = CalendarFixtureConfiguration().args.contains("--native-surfaces")
    private let preparationGPU = LiveGPUState()
    var selected: Date
    var published: LivePage?
    var width = 0, scale = 0
    var generation = 0
    var onReady: ((LivePage) -> Void)?
    var onStatus: ((String) -> Void)?
    private let worker = OperationQueue()
    private var cache: [Date: LivePage] = [:]
    private var preparing = Set<Date>()
    init() {
        store = FixtureStore(config); selected = store.anchor
        worker.maxConcurrentOperationCount = 1; worker.qualityOfService = .userInitiated
        LiveLog.shared.add("fixture", store.fixtureSummary)
    }
    func configure(width: Int, scale: Int) {
        guard width > 48, scale > 0, width != self.width || scale != self.scale else { return }
        self.width = width; self.scale = scale
        clear()
    }
    func clear() {
        generation += 1; cache.removeAll(); preparing.removeAll(); worker.cancelAllOperations()
        LiveLog.shared.add("eviction", ["generation": generation])
        request(selected)
    }
    func move(_ delta: Int) {
        request(store.calendar.date(byAdding: .day, value: delta*5, to: selected)!)
    }
    func request(_ date: Date) {
        selected = date
        onStatus?("Preparing \(date.formatted(date: .abbreviated, time: .omitted))")
        LiveLog.shared.add("pageRequest", ["date": date.timeIntervalSince1970, "cached": cache[date] != nil])
        if let page = cache[date] { publish(page); return }
        schedule(date, priority: .veryHigh)
    }
    private func publish(_ page: LivePage) {
        published = page; onReady?(page)
        onStatus?(page.date.formatted(date: .abbreviated, time: .omitted))
        LiveLog.shared.add("pageReady", ["date": page.date.timeIntervalSince1970, "estimatedBytes": page.bytes, "events": page.events])
        for delta in [-5, 5] {
            schedule(store.calendar.date(byAdding: .day, value: delta, to: selected)!, priority: .low)
        }
    }
    private func schedule(_ date: Date, priority: Operation.QueuePriority) {
        guard width > 48, cache[date] == nil, !preparing.contains(date) else { return }
        let allowed = Set([-5,0,5].map { store.calendar.date(byAdding: .day, value: $0, to: selected)! })
        cache = cache.filter { allowed.contains($0.key) }
        preparing.insert(date)
        let generation = generation, width = width, scale = scale, calendar = store.calendar
        let gpu = preparationGPU, nativeSurfaces = nativeSurfaces
        let memoText = config.args.contains("--memo-text")
        let inputs = (0..<5).map { offset -> (Date, [Fixture]) in
            let day = calendar.date(byAdding: .day, value: offset, to: date)!
            return (day, store.day(day))
        }
        let operation = BlockOperation()
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let began = CACurrentMediaTime()
            let layouts = inputs.map { DayGeometry(date: $0.0, calendar: calendar, events: $0.1) }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let palette = FixturePalette.fills.map { $0.converted(to: colorSpace, intent: .defaultIntent, options: nil)!.components! }
            var events: [[String: Any]] = []
            for (day, geometry) in layouts.enumerated() {
                for item in geometry.placements {
                    let r = item.rect(day: day, dayCount: layouts.count, width: CGFloat(width), height: 1920, gutter: 48)
                    events.append(["id": "\(day):\(item.id)", "title": item.title ?? "Event \(item.id)",
                        "rect": [r.minX,r.minY,r.width,r.height], "color": palette[item.calendarIndex]])
                }
            }
            let object: [String: Any] = ["width": width, "scale": scale, "days": 5, "events": events,
                "cgPaths": true, "reusePictures": true, "recordOnly": true, "memoText": memoText,
                "tileCount": 8, "pictureLimit": 8388608,
                "separator": CGColor(gray: 0.5, alpha: 1).converted(to: colorSpace, intent: .defaultIntent, options: nil)!.components!]
            guard operation?.isCancelled == false, let data = try? JSONSerialization.data(withJSONObject: object),
                let pointer = String(decoding: data, as: UTF8.self).withCString({ prepareLive($0) }) else { return }
            var surfaces: [CVPixelBuffer] = []
            if nativeSurfaces {
                if gpu.context == nil, let device = MTLCreateSystemDefaultDevice() {
                    gpu.context = createRenderer(Unmanaged.passUnretained(device as AnyObject).toOpaque())
                }
                guard let context = gpu.context, let pixels = rasterPage(context, pointer) else {
                    releaseLive(pointer)
                    LiveLog.shared.add("preparationFailed", ["date": date.timeIntervalSince1970])
                    return
                }
                surfaces = Unmanaged<NSArray>.fromOpaque(pixels).takeRetainedValue() as! [CVPixelBuffer]
            }
            let page = LivePage(pointer, date: date, width: width, scale: scale, events: events.count, surfaces: surfaces)
            LiveLog.shared.add("prepared", ["date": date.timeIntervalSince1970, "durationMS": (CACurrentMediaTime()-began)*1000,
                "estimatedBytes": page.bytes, "surfaceBytes": surfaces.reduce(0) { $0 + CVPixelBufferGetDataSize($1) },
                "events": events.count, "generation": generation])
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.width == width, self.scale == scale else { return }
                self.preparing.remove(date)
                let distance = abs(date.timeIntervalSince(self.selected))
                guard distance <= 5*86400+3600 else { return }
                self.cache[date] = page
                if self.selected == date { self.publish(page) }
            }
        }
        worker.addOperation(operation)
    }
}
