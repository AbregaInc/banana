import Foundation

/// Playback speed, the same list on every device. A show keeps one speed: set it on the phone,
/// the iPad, the Mac or the Watch and it is that show's speed everywhere.
enum PlaybackSpeeds {
    static let options: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The Watch plays its downloaded episodes with AVAudioPlayer, which goes from 0.5× to 2×.
    static let watchRange: ClosedRange<Double> = 0.5...2.0
    static let watchOptions: [Double] = options.filter(watchRange.contains)

    /// A show's speed as the Watch can play it: 2.5× and 3× play at 2×.
    static func onWatch(_ speed: Double) -> Double {
        min(max(speed, watchRange.lowerBound), watchRange.upperBound)
    }

    /// The next speed up from `speed`, round to the slowest after the fastest: what a tap on the
    /// speed button does. A speed that isn't in the list goes to the next one above it.
    static func next(after speed: Double, in options: [Double] = options) -> Double {
        options.first { $0 > speed + 0.001 } ?? options.first ?? 1
    }

    /// "1×", "1.5×", "1.25×".
    static func label(_ speed: Double) -> String {
        let text = speed == speed.rounded() ? String(Int(speed))
            : String(format: (speed * 10).rounded() == speed * 10 ? "%.1f" : "%.2f", speed)
        return text + "\u{00D7}"
    }

    /// How long, by the clock, until the audio reaches `target` from `now` at `rate`: an ad's
    /// start comes sooner at 1.5×. Nil when it's already past.
    static func wallClock(from now: TimeInterval, to target: TimeInterval, rate: Double) -> TimeInterval? {
        guard target > now, rate > 0 else { return nil }
        return (target - now) / rate
    }

    /// Shows whose speed isn't 1×, by title, as the phone tells the Watch.
    static func nonDefault(_ speeds: [(title: String, speed: Double)]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (title, speed) in speeds where abs(speed - 1) > 0.001 && !title.isEmpty { result[title] = speed }
        return result
    }
}
