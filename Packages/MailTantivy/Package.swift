// swift-tools-version: 6.0
import PackageDescription

// Unmodified UniFFI source and release artifact from botisan-ai/tantivy.swift 0.3.4,
// commit dae1d224ef5ea5f1fa5e68c0f363585a2876e7b3. Mail uses the runtime API alone.
let package = Package(
    name: "MailTantivy", platforms: [.macOS(.v10_15), .iOS(.v13)],
    products: [.library(name: "MailTantivy", targets: ["MailTantivy"])],
    targets: [
        .binaryTarget(name: "TantivyRS",
            url: "https://github.com/botisan-ai/tantivy.swift/releases/download/0.3.4/libtantivy-rs.xcframework.zip",
            checksum: "256fb43709a74b8c0629fd2977c56a2f35a405e57a663aa19bf37f5ffabdea63"),
        .target(name: "MailTantivy", dependencies: ["TantivyRS"]),
    ])
