import Foundation

/// Lightweight resident-memory reporting for diagnosing growth. DEBUG-only.
enum MemoryLog {
    /// Current physical footprint (what jetsam measures) in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    #if DEBUG
    private static var timer: Timer?
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Supplies per-subsystem stats appended to each log line (set by the app).
    static var extraInfo: (() -> String)?

    /// Print the footprint + subsystem stats with a timestamp every `interval`
    /// seconds so growth is visible over time and attributable to a component.
    static func startPeriodicLogging(interval: TimeInterval = 20) {
        timer?.invalidate()
        let log: () -> Void = {
            let extra = extraInfo?() ?? ""
            print(String(format: "[mem] %@  %.1f MB  %@", clock.string(from: Date()), footprintMB(), extra))
        }
        log()   // print once immediately
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in log() }
    }
    #endif
}
