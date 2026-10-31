import Foundation
import os

/// Milliseconds-from-process-creation milestones for the launch path.
///
/// "First open is slow" is only fixable against numbers, and the numbers have to start where
/// the user's tap does — at process creation, which the kernel records and in-process clocks
/// can't see (dyld, static initializers, and the debug-dylib dance all happen before any of
/// our code runs). Each named mark logs once per process, so calling from a hot body is free
/// after the first pass. Ships in release: a handful of lines per launch, and they land in the
/// playback journal too, so a device run can be measured by pulling one file.
enum LaunchClock {
    private static let log = Logger(subsystem: "com.boris.banana", category: "launch")

    /// The kernel's record of when this process was created.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    nonisolated(unsafe) private static var seen = Set<String>()
    private static let lock = NSLock()

    /// Record a milestone (first call per name wins; later calls are a set-lookup no-op).
    static func mark(_ name: StaticString) {
        let key = "\(name)"
        lock.lock()
        let isFirst = seen.insert(key).inserted
        lock.unlock()
        guard isFirst else { return }
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        log.notice("⏱ \(key, privacy: .public) +\(ms)ms")
        PlaybackDiagnostics.shared.log("⏱ \(key)", "+\(ms)ms")
    }
}
