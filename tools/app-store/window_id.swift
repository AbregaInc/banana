import CoreGraphics
import Foundation

guard let requestedPID = CommandLine.arguments.dropFirst().first.flatMap(Int32.init) else {
    fputs("Usage: window_id <pid>\n", stderr)
    exit(2)
}
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

let matches = windows.filter { window in
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int32 ?? -1
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
    return ownerPID == requestedPID && layer == 0 && alpha > 0
}

func area(_ window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double else { return 0 }
    return width * height
}

guard let match = matches.max(by: { area($0) < area($1) }),
      let number = match[kCGWindowNumber as String] as? Int else {
    fputs("No visible window owned by PID \(requestedPID)\n", stderr)
    exit(1)
}
print(number)
