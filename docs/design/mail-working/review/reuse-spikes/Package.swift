// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "sqlspike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(name: "sqlspike",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
    ])
