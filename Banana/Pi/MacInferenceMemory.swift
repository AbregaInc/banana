#if os(macOS)
import Darwin
import Foundation

/// A lower-bound estimate of headroom. Inactive anonymous pages may require swapping;
/// the system's speculative pages are already included in free_count on Darwin.
struct MacInferenceMemory {
    let pressure: Int32
    let headroom: UInt64
    let physicalBytes: UInt64
    var swapoutBytes: UInt64 = 0

    static let gib: UInt64 = 1 << 30
    // Admission keeps its conservative allocation allowance even for smaller qualified worker caches.
    static let coldCacheAllowance = 2 * gib
    // Separate the backend envelope from memory left available to foreground applications.
    // For the bundled 4B, 3.03 GB weights + cache + scratch exceeds the observed 5.8 GB
    // peak GPU allocation (tools/pi-evaluation/RESULTS-SWIFT-MLX-2026-11-01.md).
    static let runtimeScratch = gib
    var reserve: UInt64 { min(8 * Self.gib, max(2 * Self.gib, physicalBytes / 16)) }

    static func current() -> Self? {
        var level: Int32 = 0
        var size = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // At least this many inactive pages must be file-backed, even if every anonymous
        // page is inactive. Purgeable anonymous memory is independently reclaimable.
        let inactive = UInt64(vm.inactive_count)
        let anonymous = UInt64(vm.internal_page_count)
        let inactiveFiles = inactive > anonymous ? inactive - anonymous : 0
        let pages = UInt64(vm.free_count) + UInt64(vm.purgeable_count) + inactiveFiles
        return Self(pressure: level, headroom: pages * UInt64(vm_kernel_page_size),
                    physicalBytes: ProcessInfo.processInfo.physicalMemory, swapoutBytes: vm.swapouts * UInt64(vm_kernel_page_size))
    }

    /// Detect a burst in the machine-wide swap counter. It does not identify the
    /// responsible process. A worker doing inference yields to the foreground apps.
    struct SwapWindow {
        static let limit: UInt64 = 128 << 20
        private var samples: [(time: ContinuousClock.Instant, bytes: UInt64)] = []

        mutating func clear() { samples.removeAll(keepingCapacity: true) }

        mutating func exceedsLimit(_ bytes: UInt64, at time: ContinuousClock.Instant) -> Bool {
            if let last = samples.last, bytes < last.bytes || time < last.time { clear() }
            samples.removeAll { $0.time.duration(to: time) > .seconds(10) }
            if let first = samples.first, bytes - first.bytes >= Self.limit { return true }
            // Readiness and completion may check repeatedly within one second.
            if samples.last.map({ $0.time.duration(to: time) >= .milliseconds(250) }) ?? true {
                samples.append((time, bytes))
            }
            return false
        }
    }

    func admits(weightBytes: UInt64, resident: Bool) -> Bool {
        guard pressure == Int32(DispatchSource.MemoryPressureEvent.normal.rawValue) else { return false }
        // Once the weights are loaded, macOS pressure and active swapout govern yielding.
        // Keep the foreground reserve for cold allocation so reclaimed file cache can serve the app.
        if resident { return true }
        guard headroom >= reserve else { return false }
        let available = headroom - reserve
        let overhead = Self.coldCacheAllowance + Self.runtimeScratch
        return weightBytes > 0 && available >= overhead && weightBytes <= available - overhead
    }
}
#endif
