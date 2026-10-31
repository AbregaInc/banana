import CryptoKit
import Foundation
import PerfControlCore
import PerformanceContracts

private let defaultBundleIdentifier = "com.boris.banana"

private enum PerfCLIError: LocalizedError {
    case usage(String)
    case commandFailed(command: String, status: Int32, log: URL?)
    case missingFile(URL)
    case runDirectoryExists(URL)
    case resultTimedOut
    case collectedBundleMissing(String)
    case preparationMismatch
    case traceMetadataMissing(URL)

    var errorDescription: String? {
        switch self {
        case .usage(let detail): return detail
        case .commandFailed(let command, let status, let log):
            return "\(command) failed with status \(status)"
                + (log.map { "; log: \($0.path)" } ?? "")
        case .missingFile(let url): return "Required file is missing: \(url.path)"
        case .runDirectoryExists(let url): return "Run directory already exists: \(url.path)"
        case .resultTimedOut: return "Timed out waiting for the app's result.json."
        case .collectedBundleMissing(let runID):
            return "The copied app container did not contain run \(runID)."
        case .preparationMismatch:
            return "The requested device does not match the prepared run."
        case .traceMetadataMissing(let url):
            return "Trace metadata is missing or invalid: \(url.path)"
        }
    }
}

private struct HostPreparation: Codable {
    var schemaVersion = 1
    var createdAt: Date
    var deviceID: String
    var bundleIdentifier: String?
    var fixtureFilename: String
    var fixtureBytes: UInt64
    var request: PerformanceScenarioRequest
}

private struct CommandResult: Codable {
    var runDirectory: String
    var summary: PerformanceRunSummary
}

private func usage() -> Never {
    let text = """
    usage:
      perfctl validate <run-directory>
      perfctl devices [--output <raw-json-path>]
      perfctl run-simulator --device <UDID> [--scenario playback.local|planner.refresh|planner.dense|artwork.decode|control.idle]
          [--audio <path>] [--duration <seconds>]
          [--sample-interval <seconds>] [--settle <seconds>] [--output <directory>]
      perfctl prepare-device --device <ID> (--dedicated-device | --personal-device)
          [--scenario playback.local|planner.refresh|planner.dense|artwork.decode|control.idle] [--audio <path>]
          [--duration <seconds>] [--sample-interval <seconds>] [--settle <seconds>]
          [--variant <name>] [--bundle-id <installed-app-identity>]
          [--entitlements <path>] [--strip-extensions --signing-identity <SHA-1>]
          [--derived-data <persistent-directory>]
          [--output <directory>]
      perfctl launch-device --run-dir <prepared-run-directory>
      perfctl collect-device --run-dir <prepared-run-directory>
      perfctl import-trace --run-dir <prepared-run-directory> --trace <power-trace.aar>
      perfctl analyze-trace --run-dir <prepared-run-directory>
    """
    fputs("\(text)\n", stderr)
    exit(64)
}

private func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name),
          arguments.indices.contains(index + 1),
          !arguments[index + 1].hasPrefix("--")
    else { return nil }
    return arguments[index + 1]
}

private func requiredOption(_ name: String, in arguments: [String]) throws -> String {
    guard let value = option(name, in: arguments) else {
        throw PerfCLIError.usage("Missing required option \(name).")
    }
    return value
}

private func numberOption(
    _ name: String,
    default defaultValue: Double,
    allowZero: Bool = false,
    in arguments: [String]
) throws -> Double {
    guard let raw = option(name, in: arguments) else { return defaultValue }
    guard let value = Double(raw),
          value.isFinite,
          allowZero ? value >= 0 : value > 0 else {
        throw PerfCLIError.usage(
            "\(name) must be a finite \(allowZero ? "non-negative" : "positive") number.")
    }
    return value
}

private func scenarioOption(in arguments: [String]) throws -> String {
    let scenario = option("--scenario", in: arguments) ?? "playback.local"
    guard PerformanceScenarioRequest.supportedScenarioIDs.contains(scenario) else {
        throw PerfCLIError.usage(
            "--scenario must be one of: \(PerformanceScenarioRequest.supportedScenarioIDs.joined(separator: ", ")).")
    }
    return scenario
}

@discardableResult
private func run(
    _ executable: String,
    _ arguments: [String],
    log: URL? = nil,
    allowFailure: Bool = false
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe: Pipe?
    var logHandle: FileHandle?
    if let log {
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        logHandle = handle
        pipe = nil
    } else {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        pipe = output
    }

    try process.run()
    process.waitUntilExit()
    try? logHandle?.close()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    let output = String(decoding: data, as: UTF8.self)
    guard allowFailure || process.terminationStatus == 0 else {
        throw PerfCLIError.commandFailed(
            command: ([executable] + arguments).joined(separator: " "),
            status: process.terminationStatus,
            log: log)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func repositoryRoot() throws -> URL {
    let current = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true)
    guard FileManager.default.fileExists(
        atPath: current.appendingPathComponent("Banana.xcodeproj").path)
    else {
        throw PerfCLIError.usage(
            "Run perfctl from the repository root containing Banana.xcodeproj.")
    }
    return current
}

private func absoluteURL(_ path: String, relativeTo root: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return root.appendingPathComponent(path).standardizedFileURL
}

private func gitCommit(root: URL) throws -> String {
    let commit = try run(
        "/usr/bin/git",
        ["-C", root.path, "rev-parse", "HEAD"])
    let dirty = try run(
        "/usr/bin/git",
        ["-C", root.path, "status", "--porcelain", "--untracked-files=no"])
    return dirty.isEmpty ? commit : "\(commit)-dirty"
}

private func digestAndSize(_ url: URL) throws -> (digest: String, bytes: UInt64) {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw PerfCLIError.missingFile(url)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    var bytes: UInt64 = 0
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
        bytes += UInt64(data.count)
    }
    return (
        "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined(),
        bytes)
}

private func makePreparation(
    deviceID: String,
    bundleIdentifier: String?,
    scenarioID: String,
    audio: URL?,
    duration: Double,
    sampleInterval: Double,
    settle: Double,
    variant: String,
    root: URL
) throws -> HostPreparation {
    let fixture: (digest: String, bytes: UInt64)
    if let audio {
        fixture = try digestAndSize(audio)
    } else {
        fixture = (
            PerformanceScenarioRequest.builtinFixtureDigest(for: scenarioID)
                ?? "unverified",
            0
        )
    }
    return HostPreparation(
        createdAt: Date(),
        deviceID: deviceID,
        bundleIdentifier: bundleIdentifier,
        fixtureFilename: audio?.lastPathComponent ?? "",
        fixtureBytes: fixture.bytes,
        request: PerformanceScenarioRequest(
            scenarioID: scenarioID,
            runID: UUID().uuidString,
            durationSeconds: duration,
            sampleIntervalSeconds: sampleInterval,
            settleSeconds: settle,
            variant: variant,
            gitCommit: try gitCommit(root: root),
            fixtureDigest: fixture.digest))
}

private func runRoot(
    output: URL,
    runID: String
) throws -> URL {
    let directory = output.appendingPathComponent(runID, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw PerfCLIError.runDirectoryExists(directory)
    }
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("host", isDirectory: true),
        withIntermediateDirectories: true)
    return directory
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func writePreparation(_ preparation: HostPreparation, to directory: URL) throws {
    let data = try encoder().encode(preparation)
    try data.write(
        to: directory
            .appendingPathComponent("host", isDirectory: true)
            .appendingPathComponent("preparation.json"),
        options: .atomic)
}

private func readPreparation(from directory: URL) throws -> HostPreparation {
    let url = directory
        .appendingPathComponent("host", isDirectory: true)
        .appendingPathComponent("preparation.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw PerfCLIError.missingFile(url)
    }
    return try decoder().decode(HostPreparation.self, from: Data(contentsOf: url))
}

private func build(
    root: URL,
    derivedData: URL,
    destination: String,
    signed: Bool,
    bundleIdentifier: String?,
    entitlements: String?,
    stripEmbeddedExtensions: Bool,
    signingIdentity: String?,
    log: URL
) throws -> URL {
    var arguments = [
        "xcodebuild", "-quiet",
        "-project", root.appendingPathComponent("Banana.xcodeproj").path,
        "-scheme", "Banana",
        "-configuration", "Release",
        "-destination", destination,
        "-derivedDataPath", derivedData.path,
        "OTHER_SWIFT_FLAGS=$(inherited) -DPERFORMANCE_TESTING",
    ]
    if !signed {
        arguments.append("CODE_SIGNING_ALLOWED=NO")
    }
    if let bundleIdentifier {
        arguments.append("PRODUCT_BUNDLE_IDENTIFIER=\(bundleIdentifier)")
    }
    if let entitlements {
        arguments.append("CODE_SIGN_ENTITLEMENTS=\(entitlements)")
    }
    arguments.append("build")
    try run("/usr/bin/xcrun", arguments, log: log)
    let platform = signed ? "Release-iphoneos" : "Release-iphonesimulator"
    let app = derivedData
        .appendingPathComponent("Build/Products")
        .appendingPathComponent(platform)
        .appendingPathComponent("Banana.app")
    guard FileManager.default.fileExists(atPath: app.path) else {
        throw PerfCLIError.missingFile(app)
    }
    if stripEmbeddedExtensions {
        guard let entitlements, let signingIdentity else {
            throw PerfCLIError.usage(
                "--strip-extensions requires --entitlements and --signing-identity.")
        }
        for embeddedDirectory in ["PlugIns", "Watch"] {
            let url = app.appendingPathComponent(embeddedDirectory, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try run(
            "/usr/bin/codesign",
            [
                "--force",
                "--sign", signingIdentity,
                "--entitlements", root.appendingPathComponent(entitlements).path,
                "--generate-entitlement-der",
                "--timestamp=none",
                app.path,
            ],
            log: log)
    }
    return app
}

private func copyRunBundle(
    from source: URL,
    to runRoot: URL,
    runID: String
) throws -> URL {
    var bundle: URL?
    if FileManager.default.fileExists(
        atPath: source.appendingPathComponent("manifest.json").path) {
        bundle = source
    } else if let enumerator = FileManager.default.enumerator(
        at: source,
        includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let file as URL in enumerator where file.lastPathComponent == "manifest.json" {
            if let manifest = try? decoder().decode(
                PerformanceRunManifest.self,
                from: Data(contentsOf: file)),
               manifest.runID == runID {
                bundle = file.deletingLastPathComponent()
                break
            }
        }
    }
    guard let bundle else {
        throw PerfCLIError.collectedBundleMissing(runID)
    }
    let destination = runRoot.appendingPathComponent("run", isDirectory: true)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: bundle, to: destination)
    return destination
}

private func printSummary(runDirectory: URL) throws {
    let summary = try PerformanceBundleValidator.validate(directory: runDirectory)
    let result = CommandResult(runDirectory: runDirectory.path, summary: summary)
    FileHandle.standardOutput.write(try encoder().encode(result))
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func runSimulator(arguments: [String]) throws {
    let root = try repositoryRoot()
    let device = try requiredOption("--device", in: arguments)
    let scenario = try scenarioOption(in: arguments)
    let audio: URL?
    if scenario == "playback.local" {
        audio = absoluteURL(try requiredOption("--audio", in: arguments), relativeTo: root)
    } else {
        audio = option("--audio", in: arguments).map { absoluteURL($0, relativeTo: root) }
    }
    let duration = try numberOption("--duration", default: 10, in: arguments)
    let sampleInterval = try numberOption(
        "--sample-interval", default: 2, in: arguments)
    let settle = try numberOption(
        "--settle", default: 0, allowZero: true, in: arguments)
    let output = absoluteURL(
        option("--output", in: arguments) ?? "PerformanceRuns",
        relativeTo: root)
    let preparation = try makePreparation(
        deviceID: device,
        bundleIdentifier: nil,
        scenarioID: scenario,
        audio: audio,
        duration: duration,
        sampleInterval: sampleInterval,
        settle: settle,
        variant: option("--variant", in: arguments) ?? "baseline",
        root: root)
    let directory = try runRoot(output: output, runID: preparation.request.runID)
    try writePreparation(preparation, to: directory)
    let host = directory.appendingPathComponent("host", isDirectory: true)
    let persistentDerived = option("--derived-data", in: arguments)
        .map { absoluteURL($0, relativeTo: root) }
    let derived = persistentDerived
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("BananaPerformance-\(preparation.request.runID)")
    defer {
        if persistentDerived == nil {
            try? FileManager.default.removeItem(at: derived)
        }
    }
    let app = try build(
        root: root,
        derivedData: derived,
        destination: "platform=iOS Simulator,id=\(device)",
        signed: false,
        bundleIdentifier: nil,
        entitlements: nil,
        stripEmbeddedExtensions: false,
        signingIdentity: nil,
        log: host.appendingPathComponent("build.log"))

    _ = try run(
        "/usr/bin/xcrun",
        ["simctl", "uninstall", device, defaultBundleIdentifier],
        allowFailure: true)
    try run("/usr/bin/xcrun", ["simctl", "install", device, app.path])
    let container = URL(fileURLWithPath: try run(
        "/usr/bin/xcrun",
        ["simctl", "get_app_container", device, defaultBundleIdentifier, "data"]),
        isDirectory: true)
    if let audio {
        let fixtureDirectory = container
            .appendingPathComponent("Documents/PerformanceFixtures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true)
        let seededAudio = fixtureDirectory.appendingPathComponent(
            "audio." + (audio.pathExtension.isEmpty ? "m4a" : audio.pathExtension))
        try FileManager.default.copyItem(at: audio, to: seededAudio)
    }

    let stdout = host.appendingPathComponent("app.stdout.log")
    let stderr = host.appendingPathComponent("app.stderr.log")
    try run(
        "/usr/bin/xcrun",
        [
            "simctl", "launch", "--terminate-running-process",
            "--stdout=\(stdout.path)", "--stderr=\(stderr.path)",
            device, defaultBundleIdentifier,
        ] + PerformanceLaunchArguments.make(for: preparation.request))

    let source = container
        .appendingPathComponent("Documents/PerformanceRuns", isDirectory: true)
        .appendingPathComponent(preparation.request.runID, isDirectory: true)
    let timeout = Date().addingTimeInterval(
        preparation.request.durationSeconds
            + preparation.request.settleSeconds
            + 90)
    while !FileManager.default.fileExists(
        atPath: source.appendingPathComponent("result.json").path) {
        guard Date() < timeout else { throw PerfCLIError.resultTimedOut }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let normalized = try copyRunBundle(
        from: source,
        to: directory,
        runID: preparation.request.runID)
    try printSummary(runDirectory: normalized)
}

private func prepareDevice(arguments: [String]) throws {
    let root = try repositoryRoot()
    let device = try requiredOption("--device", in: arguments)
    let scenario = try scenarioOption(in: arguments)
    let audio: URL?
    if scenario == "playback.local" {
        audio = absoluteURL(try requiredOption("--audio", in: arguments), relativeTo: root)
    } else {
        audio = option("--audio", in: arguments).map { absoluteURL($0, relativeTo: root) }
    }
    do {
        _ = try PerformanceDevicePreparationPolicy.validate(
            scenarioID: scenario,
            hasAudioFixture: audio != nil,
            dedicatedDevice: arguments.contains("--dedicated-device"),
            personalDevice: arguments.contains("--personal-device"))
    } catch let error as PerformanceDevicePreparationPolicyError {
        let message: String
        switch error {
        case .missingDeviceUseAcknowledgement:
            message = "prepare-device requires exactly one of --dedicated-device or --personal-device."
        case .conflictingDeviceUseAcknowledgements:
            message = "Use only one of --dedicated-device or --personal-device."
        case .audibleScenarioRequiresDedicatedDevice:
            message = "playback.local is audible and is refused on --personal-device; use planner.refresh or control.idle."
        case .personalDeviceCannotSeedAudio:
            message = "--personal-device refuses audio fixtures; remove --audio for a silent run."
        }
        throw PerfCLIError.usage(message)
    }
    let duration = try numberOption("--duration", default: 28_800, in: arguments)
    let sampleInterval = try numberOption(
        "--sample-interval", default: 60, in: arguments)
    let settle = try numberOption(
        "--settle", default: 60, allowZero: true, in: arguments)
    let bundleIdentifier = option("--bundle-id", in: arguments) ?? defaultBundleIdentifier
    let entitlements = option("--entitlements", in: arguments)
    let stripEmbeddedExtensions = arguments.contains("--strip-extensions")
    let signingIdentity = option("--signing-identity", in: arguments)
    let variant = option("--variant", in: arguments) ?? "baseline"
    let output = absoluteURL(
        option("--output", in: arguments) ?? "PerformanceRuns",
        relativeTo: root)
    let preparation = try makePreparation(
        deviceID: device,
        bundleIdentifier: bundleIdentifier,
        scenarioID: scenario,
        audio: audio,
        duration: duration,
        sampleInterval: sampleInterval,
        settle: settle,
        variant: variant,
        root: root)
    let directory = try runRoot(output: output, runID: preparation.request.runID)
    try writePreparation(preparation, to: directory)
    let host = directory.appendingPathComponent("host", isDirectory: true)
    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "info", "details",
            "--device", device,
            "--json-output", host.appendingPathComponent("device-before.json").path,
            "--log-output", host.appendingPathComponent("device-before.log").path,
        ])
    let persistentDerived = option("--derived-data", in: arguments)
        .map { absoluteURL($0, relativeTo: root) }
    let derived = persistentDerived
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("BananaPerformance-\(preparation.request.runID)")
    defer {
        if persistentDerived == nil {
            try? FileManager.default.removeItem(at: derived)
        }
    }
    let app = try build(
        root: root,
        derivedData: derived,
        destination: "generic/platform=iOS",
        signed: true,
        bundleIdentifier: bundleIdentifier,
        entitlements: entitlements,
        stripEmbeddedExtensions: stripEmbeddedExtensions,
        signingIdentity: signingIdentity,
        log: host.appendingPathComponent("build.log"))

    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "install", "app",
            "--device", device, app.path,
            "--json-output", host.appendingPathComponent("install.json").path,
            "--log-output", host.appendingPathComponent("install.log").path,
        ])
    if let audio {
        try run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "copy", "to",
                "--device", device,
                "--source", audio.path,
                "--destination", "Documents/PerformanceFixtures/\(audio.lastPathComponent)",
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleIdentifier,
                "--json-output", host.appendingPathComponent("seed.json").path,
                "--log-output", host.appendingPathComponent("seed.log").path,
            ])
    }
    let response: [String: Any] = [
        "runDirectory": directory.path,
        "runID": preparation.request.runID,
        "next": ".build/debug/perfctl launch-device --run-dir \(directory.path)",
    ]
    let data = try JSONSerialization.data(
        withJSONObject: response,
        options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func launchDevice(arguments: [String]) throws {
    let root = try repositoryRoot()
    let directory = absoluteURL(
        try requiredOption("--run-dir", in: arguments),
        relativeTo: root)
    let preparation = try readPreparation(from: directory)
    let bundleIdentifier = preparation.bundleIdentifier ?? defaultBundleIdentifier
    let host = directory.appendingPathComponent("host", isDirectory: true)
    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "info", "details",
            "--device", preparation.deviceID,
            "--json-output", host.appendingPathComponent("device-at-launch.json").path,
            "--log-output", host.appendingPathComponent("device-at-launch.log").path,
        ])
    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "process", "launch",
            "--device", preparation.deviceID,
            "--terminate-existing",
            "--json-output", host.appendingPathComponent("launch.json").path,
            "--log-output", host.appendingPathComponent("launch.log").path,
            bundleIdentifier,
        ] + PerformanceLaunchArguments.make(for: preparation.request))
    let action: String
    if preparation.request.isTetheredMeasurement {
        action = "Leave the phone connected and untouched. This tethered scenario never starts audio."
    } else if preparation.request.scenarioID == "planner.refresh" {
        action = "Disconnect USB, but keep the phone unlocked. Wait for Banana to say Planner refresh complete, then lock it. This scenario never starts audio."
    } else if preparation.request.scenarioID == "playback.local" {
        action = "Disconnect USB now. Keep Airplane Mode on, lock the phone, and leave the on-device Power Profiler recording."
    } else {
        action = "Disconnect USB now, lock the phone, and leave the on-device Power Profiler recording. This scenario never starts audio."
    }
    let response: [String: Any] = [
        "runDirectory": directory.path,
        "runID": preparation.request.runID,
        "settleSeconds": preparation.request.settleSeconds,
        "action": action,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: response,
        options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func collectDevice(arguments: [String]) throws {
    let root = try repositoryRoot()
    let directory = absoluteURL(
        try requiredOption("--run-dir", in: arguments),
        relativeTo: root)
    let preparation = try readPreparation(from: directory)
    let bundleIdentifier = preparation.bundleIdentifier ?? defaultBundleIdentifier
    let host = directory.appendingPathComponent("host", isDirectory: true)
    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "info", "details",
            "--device", preparation.deviceID,
            "--json-output", host.appendingPathComponent("device-at-collection.json").path,
            "--log-output", host.appendingPathComponent("device-at-collection.log").path,
        ])
    let incoming = directory.appendingPathComponent("incoming", isDirectory: true)
    try? FileManager.default.removeItem(at: incoming)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try run(
        "/usr/bin/xcrun",
        [
            "devicectl", "device", "copy", "from",
            "--device", preparation.deviceID,
            "--source", "Documents/PerformanceRuns/\(preparation.request.runID)",
            "--destination", incoming.path,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundleIdentifier,
            "--json-output", host.appendingPathComponent("collect.json").path,
            "--log-output", host.appendingPathComponent("collect.log").path,
        ])
    let normalized = try copyRunBundle(
        from: incoming,
        to: directory,
        runID: preparation.request.runID)
    try? FileManager.default.removeItem(at: incoming)
    try printSummary(runDirectory: normalized)
}

private func importTrace(arguments: [String]) throws {
    let root = try repositoryRoot()
    let directory = absoluteURL(
        try requiredOption("--run-dir", in: arguments),
        relativeTo: root)
    _ = try readPreparation(from: directory)
    let source = absoluteURL(
        try requiredOption("--trace", in: arguments),
        relativeTo: root)
    let trace = try digestAndSize(source)
    let traces = directory.appendingPathComponent("traces", isDirectory: true)
    try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
    let destination = traces.appendingPathComponent(source.lastPathComponent)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw PerfCLIError.runDirectoryExists(destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    let metadata: [String: Any] = [
        "filename": destination.lastPathComponent,
        "bytes": trace.bytes,
        "digest": trace.digest,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: metadata,
        options: [.prettyPrinted, .sortedKeys])
    try data.write(to: traces.appendingPathComponent("trace.json"), options: .atomic)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func firstFile(withExtension pathExtension: String, under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    for case let file as URL in enumerator
        where file.pathExtension.lowercased() == pathExtension.lowercased() {
        return file
    }
    return nil
}

private func analyzeTrace(arguments: [String]) throws {
    let root = try repositoryRoot()
    let directory = absoluteURL(
        try requiredOption("--run-dir", in: arguments),
        relativeTo: root)
    _ = try readPreparation(from: directory)
    let traces = directory.appendingPathComponent("traces", isDirectory: true)
    let metadataURL = traces.appendingPathComponent("trace.json")
    guard let metadata = try? JSONSerialization.jsonObject(
              with: Data(contentsOf: metadataURL)) as? [String: Any],
          let filename = metadata["filename"] as? String else {
        throw PerfCLIError.traceMetadataMissing(metadataURL)
    }
    let archive = traces.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: archive.path) else {
        throw PerfCLIError.missingFile(archive)
    }

    // Derived analysis is safe to rebuild. The immutable imported .aar and its digest remain next
    // to it, so rerunning this command under a newer Xcode never destroys the captured evidence.
    let analysisDirectory = traces.appendingPathComponent("PowerProfilerAnalysis", isDirectory: true)
    try? FileManager.default.removeItem(at: analysisDirectory)
    try FileManager.default.createDirectory(at: analysisDirectory, withIntermediateDirectories: true)
    try run("/usr/bin/aa", ["extract", "-i", archive.path, "-d", analysisDirectory.path])
    guard let atrc = firstFile(withExtension: "atrc", under: analysisDirectory) else {
        throw PerfCLIError.missingFile(analysisDirectory.appendingPathComponent("*.atrc"))
    }

    let normalizedTrace = analysisDirectory.appendingPathComponent("PowerProfiler.trace")
    _ = try run(
        "/usr/bin/xcrun",
        [
            "xctrace", "import",
            "--input", atrc.path,
            "--template", "Power Profiler",
            "--output", normalizedTrace.path,
        ],
        log: analysisDirectory.appendingPathComponent("import.log"))

    let schemas = [
        "ProcessLifecycleChange",
        "ProcessSubsystemPowerImpact",
        "SystemPowerLevel",
        "DeviceChargingState",
        "device-thermal-state-intervals",
        "network-connection-stat",
    ]
    for schema in schemas {
        _ = try run(
            "/usr/bin/xcrun",
            [
                "xctrace", "export",
                "--input", normalizedTrace.path,
                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]",
                "--output", analysisDirectory.appendingPathComponent("\(schema).xml").path,
            ],
            log: analysisDirectory.appendingPathComponent("export-\(schema).log"))
    }

    let output = analysisDirectory.appendingPathComponent("analysis.json")
    _ = try run(
        "/usr/bin/python3",
        [
            root.appendingPathComponent("tools/analyze_power_trace.py").path,
            "--tables", analysisDirectory.path,
            "--run", directory.appendingPathComponent("run", isDirectory: true).path,
            "--output", output.path,
        ],
        log: analysisDirectory.appendingPathComponent("analyze.log"))
    FileHandle.standardOutput.write(try Data(contentsOf: output))
}

private func listDevices(arguments: [String]) throws {
    let output: URL
    if let path = option("--output", in: arguments) {
        output = URL(fileURLWithPath: path)
    } else {
        output = FileManager.default.temporaryDirectory
            .appendingPathComponent("perfctl-devices-\(UUID().uuidString).json")
    }
    defer {
        if option("--output", in: arguments) == nil {
            try? FileManager.default.removeItem(at: output)
        }
    }
    try run(
        "/usr/bin/xcrun",
        ["devicectl", "list", "devices", "--json-output", output.path])
    FileHandle.standardOutput.write(try Data(contentsOf: output))
    FileHandle.standardOutput.write(Data([0x0A]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

do {
    switch command {
    case "validate":
        guard arguments.count == 2 else { usage() }
        try printSummary(
            runDirectory: URL(
                fileURLWithPath: arguments[1],
                isDirectory: true))
    case "devices":
        try listDevices(arguments: Array(arguments.dropFirst()))
    case "run-simulator":
        try runSimulator(arguments: Array(arguments.dropFirst()))
    case "prepare-device":
        try prepareDevice(arguments: Array(arguments.dropFirst()))
    case "launch-device":
        try launchDevice(arguments: Array(arguments.dropFirst()))
    case "collect-device":
        try collectDevice(arguments: Array(arguments.dropFirst()))
    case "import-trace":
        try importTrace(arguments: Array(arguments.dropFirst()))
    case "analyze-trace":
        try analyzeTrace(arguments: Array(arguments.dropFirst()))
    default:
        usage()
    }
} catch {
    fputs("perfctl: \(error.localizedDescription)\n", stderr)
    exit(1)
}
