import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Launch arguments

enum HostKind: String { case list, lazy, native }

struct LaunchArgs {
    var host: HostKind = .native
    var variant: Variant = .positionY
    var scenario: String?
    var run = 1
    var out: String?
    var uptime = ""
    var xcodebuilds = -1
    var uitest = false
    var diySwipe = false
    var diySimultaneous = false
    /// How `prepend` positions the list: "drag" (a platform-level scroll, as a finger leaves it) or "api" (the host's own).
    var via = "api"

    static let current: LaunchArgs = {
        var a = LaunchArgs()
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let v = value("--host"), let h = HostKind(rawValue: v) { a.host = h }
        if let v = value("--variant"), let x = Variant(rawValue: v) { a.variant = x }
        a.scenario = value("--scenario")
        a.run = Int(value("--run") ?? "1") ?? 1
        a.out = value("--out")
        a.uptime = value("--uptime") ?? ""
        a.xcodebuilds = Int(value("--xcodebuilds") ?? "-1") ?? -1
        a.uitest = args.contains("--uitest")
        a.diySwipe = args.contains("--diy-swipe") || args.contains("--diy-swipe-simultaneous")
        a.diySimultaneous = args.contains("--diy-swipe-simultaneous")
        a.via = value("--via") ?? "api"
        return a
    }()
}

// MARK: - Display clock

/// Per-display-frame callback. The app's `FrameProbe` is `#if DEBUG && os(iOS)` and reports through
/// `PlaybackDiagnostics`, so it is not self-contained; this is the same instrument (a `CADisplayLink`
/// on the main run loop, a hitch being an interval over twice the display's frame duration) with the
/// per-frame samples kept instead of 1 s windows. iOS: `CADisplayLink`; Mac: `NSScreen.displayLink`.
@MainActor
final class DisplayClock: NSObject {
    struct Tick { var time: Double; var dt: Double; var frameDuration: Double }

    var onTick: ((Tick) -> Void)?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    var maxFPS: Int {
        #if os(iOS)
        UIScreen.main.maximumFramesPerSecond
        #else
        (MacDelegate.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        #endif
    }

    func start() {
        #if os(iOS)
        let l = CADisplayLink(target: self, selector: #selector(fire(_:)))
        #else
        let l = (MacDelegate.screen ?? NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(fire(_:)))
        #endif
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func fire(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = last > 0 ? now - last : 0
        last = now
        onTick?(Tick(time: now, dt: dt, frameDuration: l.duration))
    }
}

// MARK: - Metronome (a held key: events at a fixed rate, independent of the display)

@MainActor
final class Metronome {
    private var timer: DispatchSourceTimer?

    func run(count: Int, hz: Double, step: @escaping @MainActor (Int) -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var i = 0
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            let interval = 1.0 / hz
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
            t.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    step(i)
                    i += 1
                    if i >= count {
                        t.cancel()
                        self?.timer = nil
                        c.resume()
                    }
                }
            }
            timer = t
            t.resume()
        }
    }
}

// MARK: - Main-thread turn time

/// Time from a marked instant to the main run loop going idle: the whole turn a move causes
/// (the move itself, SwiftUI's update, Core Animation's commit). `beforeWaiting` at an order after
/// Core Animation's own observer.
@MainActor
final class TurnTimer {
    private var observer: CFRunLoopObserver?
    private(set) var pendingStart: CFTimeInterval?
    private(set) var samples: [Double] = []     // ms

    func begin() { pendingStart = CACurrentMediaTime() }

    func install() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.pendingStart else { return }
                self.samples.append((CACurrentMediaTime() - s) * 1000)
                self.pendingStart = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func remove() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}

// MARK: - Stats

enum Stats {
    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }
    static func median(_ v: [Double]) -> Double { percentile(v, 0.5) }
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}
