import Foundation

/// Audio quality for the copy sent to the Apple Watch. Transcoding to low-bitrate
/// mono shrinks the phone→watch transfer and watch storage (speech is fine at 32–48k).
///
/// Split out from AppSettings.swift — same reasoning as `DistanceUnit.swift` there — so
/// `Podcast.swift` (and BananaTests, which needs `Podcast` for its snapshot decode-and-quarantine
/// tests) can be sourced without also pulling in AppSettings' LaunchClock/CloudBackup singleton
/// dependencies, which aren't otherwise part of the test target's dependency chain.
enum WatchAudioQuality: String, Codable, CaseIterable, Identifiable {
    case original, medium, low

    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .medium:   return "Medium (48 kbps)"
        case .low:      return "Small (32 kbps)"
        }
    }
    var bitrate: Int? {   // nil = don't transcode
        switch self { case .original: return nil; case .medium: return 48_000; case .low: return 32_000 }
    }
    var sampleRate: Double {
        switch self { case .original: return 44_100; case .medium: return 32_000; case .low: return 24_000 }
    }
    var transcodes: Bool { self != .original }
}
