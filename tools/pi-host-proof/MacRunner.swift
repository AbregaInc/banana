import Foundation

@main
struct MacProof {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let databasePath = CommandLine.arguments[3]
        var finished = false
        var passed = false
        let host = try startPiProof(mode: mode, databasePath: databasePath, sourceDirectory: directory,
                                   bundleURL: directory.appendingPathComponent("pi.js")) { result, success in
            print(result)
            passed = success
            finished = true
        }
        let deadline = Date().addingTimeInterval(90)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        host.stop()
        if !finished { print("Host proof timed out") }
        exit(passed ? 0 : 1)
    }
}
