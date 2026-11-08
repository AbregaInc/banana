import Foundation

/// The checkout these tests were built from, for the tests that read the repository's own files.
///
/// Not `#filePath`: builds that share the compilation cache between worktrees (tools/config.sh)
/// compile with the checkout mapped to `/^src`, so `#filePath` names no real folder there, and a
/// test that skips when a file is missing would skip without saying why. The build writes the
/// real folder into this bundle's Info.plist as `BananaSourceRoot` (`$(SRCROOT)`, see
/// BananaTests/Info.plist), which is right however the sources were compiled.
enum SourceTree {
    static let root: URL = {
        let written = Bundle(for: Marker.self).object(forInfoDictionaryKey: "BananaSourceRoot") as? String
        if let written, !written.isEmpty, !written.hasPrefix("$(") {
            return URL(fileURLWithPath: written, isDirectory: true)
        }
        let compiled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        precondition(!compiled.path.hasPrefix("/^"),
                     "BananaTests was compiled with a mapped source path and has no BananaSourceRoot")
        return compiled
    }()

    private final class Marker {}
}
