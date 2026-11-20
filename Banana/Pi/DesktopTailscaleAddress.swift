#if os(macOS) && BANANA_AI && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import Foundation

enum DesktopTailscaleAddress {
    /// Ask the installed Tailscale client only for this Mac's own address.
    static func detect() async -> String? {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                     "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            guard !Task.isCancelled else { return nil }
            if let address = await address(from: path) { return address }
        }
        return nil
    }

    private static func address(from path: String) async -> String? {
        await withCheckedContinuation { result in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["ip", "-4"]
            process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, cli in cli }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let address = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result.resume(returning: process.terminationStatus == 0 && DesktopPeerLink.tailnetEndpoint(address) != nil ? address : nil)
            }
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                result.resume(returning: nil)
            }
        }
    }
}
#endif
