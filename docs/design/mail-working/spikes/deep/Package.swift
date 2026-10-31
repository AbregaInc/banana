// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "maildeep",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [.executableTarget(name: "maildeep", dependencies: ["SwiftSoup"],
                                swiftSettings: [.unsafeFlags(["-swift-version", "5"])])])
