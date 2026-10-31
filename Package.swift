// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BananaPerformanceInfrastructure",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerformanceContracts", targets: ["PerformanceContracts"]),
        .library(name: "PerfControlCore", targets: ["PerfControlCore"]),
        .executable(name: "perfctl", targets: ["perfctl"]),
    ],
    targets: [
        .target(
            name: "PerformanceContracts",
            path: "Shared",
            exclude: ["AlarmShared.swift", "FitnessModels.swift"],
            sources: [
                "DiagnosticsTracing.swift",
                "PerformanceContracts.swift",
                "PerformanceRunRecorder.swift",
                "WorkoutMediaRouting.swift",
            ]),
        .target(
            name: "PerfControlCore",
            dependencies: ["PerformanceContracts"],
            path: "PerformanceInfrastructure/Sources/PerfControlCore"),
        .executableTarget(
            name: "perfctl",
            dependencies: ["PerfControlCore", "PerformanceContracts"],
            path: "PerformanceInfrastructure/Sources/perfctl"),
        .testTarget(
            name: "PerfControlCoreTests",
            dependencies: ["PerfControlCore", "PerformanceContracts"],
            path: "PerformanceInfrastructure/Tests/PerfControlCoreTests"),
    ])
