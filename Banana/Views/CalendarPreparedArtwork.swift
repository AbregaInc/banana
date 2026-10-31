import SwiftUI

/// Prepared event presentation used by Beta. The viewport owns layout, gestures and durable
/// writes; immutable artwork is cached separately from reusable interactive cells.
struct CalendarPreparedArtwork: View {
    let paint: CalendarEventPaint
    let height: CGFloat
    let layout: CalendarEventArtwork.Layout
    var showsIcon = true
    @Environment(\.self) private var environment
    @State private var visible = false
    @State private var prepared: Prepared?
    @State private var preparationFailed = false

    private struct Prepared {
        let key: CalendarArtworkRasterRequest
        let lease: CalendarArtworkImageLease
    }

    private struct PreparationIdentity: Equatable {
        let key: CalendarArtworkRasterRequest
        let supportsSymbols: Bool
    }

    static var enabled: Bool {
        #if BANANA_BETA
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-prepared-artwork")
        #else
        false
        #endif
    }

    private static let groupsMobileEvents: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-event-accessibility")
        #else
        true
        #endif
    }()

    @ViewBuilder private var reference: some View {
        let artwork = CalendarEventArtwork(paint: paint, height: height, layout: layout, showsIcon: showsIcon)
        if paint.isEvent, case .mobile = layout, Self.groupsMobileEvents {
            // The cell supplies one event label. Without a single artwork element,
            // SwiftUI applies it to title/time/location separately and repeats it.
            artwork.accessibilityElement(children: .combine)
        } else {
            artwork
        }
    }

    var body: some View {
        // The action-bearing cell owns its explicit title/time/state and activation semantics.
        // VoiceOver must not silently switch an event back to the old visual renderer.
        // Specialized non-event cues retain their separate presentation for now.
        if Self.enabled && paint.isEvent {
            GeometryReader { geometry in
                let key = CalendarArtworkRasterRequest(paint: paint, size: geometry.size,
                    desktop: layout == .desktop, showsIcon: showsIcon, environment: environment, paintHeight: height)
                // Let preparation report unsupported environments. Suppressing the task
                // here would leave a visible Beta event in its pending state forever.
                let eligible = visible || environment.calendarNativeCell
                let cache = CalendarArtworkPreparation.shared.cache
                let supportsSymbols = environment.symbolRenderingMode == nil
                let direct = supportsSymbols && cache.rendering == .nativeCoreText && CalendarNativeEventCanvas.required(
                    size: geometry.size, scale: environment.displayScale, maximumImageBytes: cache.maximumEntryBytes)
                Group {
                    if direct {
                        CalendarNativeEventCanvas(request: CalendarNativeEventAdapter.request(
                            paint: paint, size: geometry.size, paintHeight: height,
                            desktop: layout == .desktop, showsIcon: showsIcon, environment: environment))
                            .accessibilityRepresentation {
                                Text(environment.redactionReasons.isEmpty ? paint.title : "Calendar event")
                                    .accessibilityIdentifier("calendar.nativeArtwork.direct")
                            }
                            #if DEBUG
                            .onAppear { Self.noteMounted(paint.title, renderer: "direct") }
                            #endif
                    } else if supportsSymbols, let prepared, prepared.key == key {
                        Image(decorative: prepared.lease.image, scale: environment.displayScale)
                            .resizable()
                            .accessibilityRepresentation {
                                Text(paint.title)
                                    .accessibilityIdentifier("calendar.preparedArtwork")
                            }
                            #if DEBUG
                            .onAppear { Self.noteMounted(paint.title, renderer: "raster") }
                            #endif
                    } else {
                        #if BANANA_BETA
                        // Beta must exercise the replacement, including its cold preparation.
                        // Never silently display the reference renderer while preparing/failing.
                        HStack(spacing: 4) {
                            Text(paint.title).font(.caption).lineLimit(2)
                            if preparationFailed {
                                Image(systemName: "exclamationmark.circle")
                                    .accessibilityLabel("Event preview unavailable; open for details")
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(paint.tint.opacity(0.15))
                        .accessibilityIdentifier(preparationFailed
                            ? "calendar.preparedArtwork.failed" : "calendar.preparedArtwork.pending")
                        #else
                        reference
                        #endif
                    }
                }
                .task(id: eligible && !direct ? PreparationIdentity(key: key, supportsSymbols: supportsSymbols) : nil) {
                    prepared = nil
                    preparationFailed = false
                    guard eligible && !direct else { return }
                    let lease = await CalendarArtworkPreparation.shared.prepare(paint: paint,
                        size: geometry.size, desktop: layout == .desktop,
                        showsIcon: showsIcon, environment: environment, paintHeight: height)
                    guard !Task.isCancelled else { return }
                    guard let lease else { preparationFailed = true; return }
                    prepared = Prepared(key: key, lease: lease)
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .onDisappear { prepared = nil; visible = false }
        } else {
            reference
        }
    }

    #if DEBUG
    private static func noteMounted(_ title: String, renderer: String) {
        guard ProcessInfo.processInfo.arguments.contains("--calendar-artwork-test-probe") else { return }
        RenderStats.note("Calendar.artwork.\(renderer):\(title)")
    }
    #endif
}

/// Tracks consumer ownership separately from the cache. Release is thread-safe because SwiftUI
/// can destroy state outside the main actor. Compositor retention must still be profiled.
final class CalendarArtworkImageLease {
    let image: CGImage
    private let release: () -> Void
    init(image: CGImage, release: @escaping () -> Void) {
        self.image = image; self.release = release
    }
    deinit { release() }
}

final class CalendarArtworkImageBudget {
    let limit: Int
    private let lock = NSLock()
    private var bytes = 0
    var retainedBytes: Int { lock.withLock { bytes } }
    init(limit: Int) { precondition(limit >= 0); self.limit = limit }
    func acquire(_ image: CGImage) -> CalendarArtworkImageLease? {
        let cost = image.bytesPerRow * image.height
        let accepted = lock.withLock {
            guard cost <= limit - bytes else { return false }
            bytes += cost
            return true
        }
        guard accepted else { return nil }
        return CalendarArtworkImageLease(image: image) { [self] in
            lock.withLock { bytes -= cost }
        }
    }
}

/// Bounded, cancellable preparation outside view evaluation/input callbacks. One image per
/// dispatch turn avoids a synchronous batch. This does not make ImageRenderer off-main or
/// guarantee a frame deadline: first-use preparation remains an explicitly measured risk.
@MainActor
final class CalendarArtworkPreparation {
    static var applicationRendering: CalendarArtworkRasterCache.Rendering {
        #if BANANA_BETA
        .nativeCoreText
        #else
        .coreGraphics
        #endif
    }
    static let shared = CalendarArtworkPreparation(cache: CalendarArtworkRasterCache(
        rendering: applicationRendering,
        recordRenderTimings: ProcessInfo.processInfo.arguments.contains("--calendar-artwork-profile")),
        defersFullQueueAdmission: !ProcessInfo.processInfo.arguments.contains("--calendar-immediate-artwork-admission"))
    let cache: CalendarArtworkRasterCache
    let consumers: CalendarArtworkImageBudget
    let pendingLimit: Int
    let queuesCacheHits: Bool
    let defersFullQueueAdmission: Bool
    private struct Job {
        let id: UUID
        let paint: CalendarEventPaint
        let size: CGSize
        let paintHeight: CGFloat?
        let desktop: Bool
        let showsIcon: Bool
        let environment: EnvironmentValues
        let continuation: CheckedContinuation<CalendarArtworkImageLease?, Never>
    }
    private var jobs: [Job] = []
    private var scheduled = false
    private let enqueueDrain: (@escaping @MainActor @Sendable () -> Void) -> Void
    var pendingCount: Int { jobs.count }
    private(set) var queueRejections = 0
    private(set) var queueAdmissionDeferrals = 0
    private(set) var queueRejectedTitles: [String] = []

    init(cache: CalendarArtworkRasterCache? = nil,
         consumerByteLimit: Int = 32 * 1024 * 1024, pendingLimit: Int = 128,
         queuesCacheHits: Bool = false, defersFullQueueAdmission: Bool = true,
         enqueueDrain: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
             DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1), execute: work)
         }) {
        precondition(pendingLimit > 0)
        self.cache = cache ?? CalendarArtworkRasterCache(); consumers = CalendarArtworkImageBudget(limit: consumerByteLimit)
        self.pendingLimit = pendingLimit; self.queuesCacheHits = queuesCacheHits
        self.defersFullQueueAdmission = defersFullQueueAdmission
        self.enqueueDrain = enqueueDrain
    }

    func prepare(paint: CalendarEventPaint, size: CGSize, desktop: Bool, showsIcon: Bool,
                 environment: EnvironmentValues, paintHeight: CGFloat? = nil) async -> CalendarArtworkImageLease? {
        guard !Task.isCancelled else { return nil }
        if !queuesCacheHits, let image = cache.cachedImage(paint: paint, size: size,
            desktop: desktop, showsIcon: showsIcon, environment: environment, paintHeight: paintHeight) {
            return consumers.acquire(image)
        }
        if defersFullQueueAdmission && jobs.count >= pendingLimit {
            // View replacement queues cancellation handlers on this actor. Let those callbacks
            // release obsolete jobs before declining a newly visible cell. One turn only:
            // never grow the queue or spin when the viewport itself exceeds the work budget.
            queueAdmissionDeferrals += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        let id = UUID()
        let lease: CalendarArtworkImageLease? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil); return
                }
                guard jobs.count < pendingLimit else {
                    queueRejections += 1
                    if cache.recordRenderTimings && queueRejectedTitles.count < 16 {
                        queueRejectedTitles.append(String(decoding: paint.title.utf8.prefix(128), as: UTF8.self))
                    }
                    continuation.resume(returning: nil); return
                }
                jobs.append(Job(id: id, paint: paint, size: size, paintHeight: paintHeight, desktop: desktop,
                    showsIcon: showsIcon, environment: environment, continuation: continuation))
                schedule()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        // The main-actor cancellation callback can run after the scheduled drain.
        // Recheck in the requesting task before handing that completed image back.
        return Task.isCancelled ? nil : lease
    }

    private func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: index).continuation.resume(returning: nil)
    }

    private func schedule() {
        guard !scheduled, !jobs.isEmpty else { return }
        scheduled = true
        enqueueDrain { [self] in
            scheduled = false
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                let image = try? cache.image(paint: job.paint, size: job.size,
                    desktop: job.desktop, showsIcon: job.showsIcon, environment: job.environment, paintHeight: job.paintHeight)
                job.continuation.resume(returning: image.flatMap { consumers.acquire($0) })
            }
            schedule()
        }
    }
}
