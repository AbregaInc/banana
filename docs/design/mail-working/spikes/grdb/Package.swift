// swift-tools-version: 5.9
// The store of docs/design/MAIL-ENGINE.md section 4, on GRDB, with the design's own schema and
// PRAGMAs. Build:  swift build -c release --build-path <somewhere outside the worktree>
import PackageDescription
let package = Package(
    name: "mailgrdb",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .executableTarget(name: "mailgrdb",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
    ])
