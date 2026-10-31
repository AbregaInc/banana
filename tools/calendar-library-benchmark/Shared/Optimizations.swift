import Foundation
import Darwin

// Explicit one-at-a-time ablations. These change implementation cost, never workload or budgets.
struct Optimizations {
    let renderer: String
    let disabled: String
    private let nativeTextRequested: Bool
    init() {
        let config = CalendarFixtureConfiguration()
        renderer = config.value("--renderer", "canvas")
        disabled = config.value("--ablation", "none")
        nativeTextRequested = config.args.contains("--raster-native-text")
    }
    // The retained microbenchmarks show bucket/hash traversal loses for our broad viewports.
    var tileScrollPreload: Bool { ["tile-scroll-prefetch", "tile-prefetch", "tile-prefetch-lookahead", "tile-prefetch-budgeted", "tile-prefetch-text-cull", "tile-prefetch-ax-cache", "tile-prefetch-ax-lazy", "tile-prefetch-native-text", "tile-prefetch-queue-one", "tile-prefetch-queue-two", "tile-prefetch-queue-two-cancel", "tile-prefetch-async-one", "tile-prefetch-async-two", "tile-prefetch-async-lazy", "tile-prefetch-async-layer", "tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var tilePagePreload: Bool { ["tile-page-prefetch", "tile-prefetch", "tile-prefetch-lookahead", "tile-prefetch-budgeted", "tile-prefetch-text-cull", "tile-prefetch-ax-cache", "tile-prefetch-ax-lazy", "tile-prefetch-native-text", "tile-prefetch-queue-one", "tile-prefetch-queue-two", "tile-prefetch-queue-two-cancel", "tile-prefetch-async-one", "tile-prefetch-async-two", "tile-prefetch-async-lazy", "tile-prefetch-async-layer", "tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var tileLookahead: Bool { ["tile-prefetch-lookahead", "tile-prefetch-budgeted", "tile-prefetch-text-cull", "tile-prefetch-ax-cache", "tile-prefetch-ax-lazy", "tile-prefetch-native-text", "tile-prefetch-queue-one", "tile-prefetch-queue-two", "tile-prefetch-queue-two-cancel", "tile-prefetch-async-one", "tile-prefetch-async-two", "tile-prefetch-async-lazy", "tile-prefetch-async-layer", "tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var tileBudgeted: Bool { ["tile-prefetch-budgeted", "tile-prefetch-text-cull", "tile-prefetch-ax-cache", "tile-prefetch-ax-lazy", "tile-prefetch-native-text", "tile-prefetch-queue-one", "tile-prefetch-queue-two", "tile-prefetch-queue-two-cancel", "tile-prefetch-async-one", "tile-prefetch-async-two", "tile-prefetch-async-lazy", "tile-prefetch-async-layer", "tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var tilePreparationConcurrency: Int { disabled == "tile-prefetch-queue-one" ? 1 : (["tile-prefetch-queue-two", "tile-prefetch-queue-two-cancel"].contains(disabled) ? 2 : 0) }
    var tileForegroundWorkers: Int { disabled == "tile-prefetch-async-one" ? 1 : (["tile-prefetch-async-two", "tile-prefetch-async-lazy", "tile-prefetch-async-layer", "tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) ? 2 : 0) }
    var tilePixelBuffer: Bool { ["tile-prefetch-async-surface", "tile-prefetch-async-surface-properties", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var nativeAccessibilityProperties: Bool { disabled == "tile-prefetch-async-surface-properties" }
    var nativeLayerUpdates: Bool { disabled == "tile-prefetch-async-layer" && renderer == "tiles" }
    var tileCooperativeCancellation: Bool { disabled == "tile-prefetch-queue-two-cancel" }
    var tileNativeText: Bool { disabled == "tile-prefetch-native-text" || nativeTextRequested }
    var tileTextCull: Bool { disabled == "tile-prefetch-text-cull" }
    var splitGrid: Bool { renderer == "canvas" && disabled == "split-grid" }
    var indexed: Bool { disabled == "force-index" }
    var heap: Bool? { disabled == "linear-lanes" ? false : (disabled == "force-heap" ? true : nil) }
    var cached: Bool { disabled != "no-cache" }
    var preload: Bool { disabled != "no-prefetch" }
    var overscan: Bool { disabled != "no-overscan" }
    var accessibilityReuse: Bool { disabled != "rebuild-accessibility" }
    var accessibilityPageCache: Bool { ["accessibility-page-cache", "tile-prefetch-ax-cache", "tile-prefetch-ax-lazy", "tile-prefetch-async-lazy", "tile-prefetch-async-surface-cache", "tile-prefetch-async-surface-lazy"].contains(disabled) }
    var accessibilityLazy: Bool {
        #if os(iOS)
        ["tile-prefetch-ax-lazy", "tile-prefetch-async-lazy", "tile-prefetch-async-surface-lazy"].contains(disabled)
        #else
        false
        #endif
    }
    var reuse: Bool { disabled != "no-reuse" }
    var textCache: Bool { disabled != "no-text-cache" }
    var textPreload: Bool { disabled != "no-text-prefetch" && textCache }
    var viewportTextPreload: Bool { disabled != "full-text-prefetch" }
    var glyphCulling: Bool { disabled != "no-glyph-culling" }
    var windowedSurface: Bool { disabled != "full-surface" }
    var rasterCache: Bool { disabled != "no-raster-cache" }
    var rasterPreload: Bool { disabled != "no-raster-prefetch" && rasterCache }
    var streamRasterPreload: Bool { disabled != "batch-raster-prefetch" }
}

func peakResidentBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

// Sampled physical footprint supplements RSS: native surfaces may be charged differently
// from ordinary heap images. This is a snapshot, not a kernel-recorded peak.
func physicalFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}
