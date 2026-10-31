import Foundation
import Darwin

// Explicit one-at-a-time ablations. These change implementation cost, never workload or budgets.
struct Optimizations {
    let renderer: String
    let disabled: String
    init() {
        let config = Configuration()
        renderer = config.value("--renderer", "canvas")
        disabled = config.value("--ablation", "none")
    }
    // The retained microbenchmarks show bucket/hash traversal loses for our broad viewports.
    var tileScrollPreload: Bool { ["tile-scroll-prefetch", "tile-prefetch"].contains(disabled) }
    var tilePagePreload: Bool { ["tile-page-prefetch", "tile-prefetch"].contains(disabled) }
    var splitGrid: Bool { renderer == "canvas" && disabled == "split-grid" }
    var indexed: Bool { disabled == "force-index" }
    var heap: Bool? { disabled == "linear-lanes" ? false : (disabled == "force-heap" ? true : nil) }
    var cached: Bool { disabled != "no-cache" }
    var preload: Bool { disabled != "no-prefetch" }
    var overscan: Bool { disabled != "no-overscan" }
    var accessibilityReuse: Bool { disabled != "rebuild-accessibility" }
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
