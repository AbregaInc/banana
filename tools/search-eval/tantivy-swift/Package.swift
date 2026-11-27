// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BananaMailReplay",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/botisan-ai/tantivy.swift.git", exact: "0.3.4")],
    targets: [
        .executableTarget(name: "Replay", dependencies: [
            .product(name: "TantivySwift", package: "tantivy.swift")
        ])
    ]
)
