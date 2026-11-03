import Foundation
import JavaScriptCore

private func proofEnvelope(_ operation: () throws -> Any) -> String {
    let result: [String: Any]
    do { result = ["ok": true, "value": try operation()] }
    catch { result = ["ok": false, "error": ["code": 0, "message": String(describing: error)]] }
    return String(decoding: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8), as: UTF8.self)
}

@MainActor
private func installProofHooks(host: AppleRuntimeHost, mode: String, databasePath: String) {
        let lifecycleSnapshot: @convention(block) (String) -> String = { [weak host] json in
            guard let host else { return "{}" }
            return proofEnvelope {
                guard var snapshot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    throw NSError(domain: "PiProof", code: 1)
                }
                snapshot["nativeDatabases"] = host.resources["databases"]!
                snapshot["nativeTimers"] = host.resources["timers"]!
                snapshot["nativeModelRequests"] = host.resources["modelRequests"]!
                snapshot["recordedAt"] = Date().timeIntervalSince1970 * 1000
                try JSONSerialization.data(withJSONObject: snapshot).write(to: URL(fileURLWithPath: databasePath + ".lifecycle.json"), options: .atomic)
                return true
            }
        }
        // A proof-only native tool; production tools will be supplied through a Pi extension.
        let probe: @convention(block) (Double) -> Double = { value in
            if mode == "crash-first" || mode == "foundation-crash-first" {
                do { try Data("native tool effect happened\n".utf8).write(to: URL(fileURLWithPath: databasePath + ".effect")) }
                catch { print("Cannot record effect: \(error)"); exit(1) }
                print("Exiting process during native tool, after Pi committed execution intent")
                fflush(stdout)
                exit(42)
            }
            return value * 2
        }
    host.context.setObject(probe, forKeyedSubscript: "nativeDouble" as NSString)
    host.context.setObject(lifecycleSnapshot, forKeyedSubscript: "nativeLifecycleSnapshot" as NSString)
    host.context.setObject(mode, forKeyedSubscript: "nativeMode" as NSString)
}

@MainActor
func startPiProof(mode: String, databasePath: String, sourceDirectory: URL, bundleURL: URL,
                  completion: @escaping (String, Bool) -> Void) throws -> AppleRuntimeHost {
    let host = try AppleRuntimeHost(databasePath: databasePath, completion: completion)
    installProofHooks(host: host, mode: mode, databasePath: databasePath)
    try host.start(sourceDirectory: sourceDirectory, bundleURL: bundleURL)
    return host
}
