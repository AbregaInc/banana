import CryptoKit
import Foundation

@main
enum ModelCatalogTest {
    static func main() throws {
        let bundled = try Data(contentsOf: URL(fileURLWithPath: "Banana/Pi/Resources/pi-local-model.json"))
        let pin = try JSONSerialization.jsonObject(with: bundled) as! [String: Any]
        let key = Curve25519.Signing.PrivateKey()
        let entry: [String: Any] = ["pin": pin, "minimumBuild": 190, "minimumMemoryGiB": 8, "runtimeABI": 1]

        func signed(_ entries: [[String: Any]], channel: String = "beta", sequence: Int = 1) throws -> Data {
            let payload = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "channel": channel, "sequence": sequence, "models": entries,
            ], options: .sortedKeys)
            return try JSONSerialization.data(withJSONObject: [
                "payload": payload.base64EncodedString(),
                "signature": key.signature(for: payload).base64EncodedString(),
            ])
        }

        func verify(_ envelope: Data, channel: String = "beta") -> ModelCatalog.Listing? {
            ModelCatalog.verify(envelope, channel: channel, key: key.publicKey.rawRepresentation)
        }

        let valid = try signed([entry])
        let decoded = verify(valid)!.models[0]
        precondition(decoded.supports(build: 190, memory: 8 << 30))
        precondition(!decoded.supports(build: 189, memory: 8 << 30))
        precondition(!decoded.supports(build: 190, memory: 7 << 30))
        precondition(verify(valid, channel: "production") == nil)
        let wrongABI = try signed([entry.merging(["runtimeABI": 2]) { _, new in new }])
        precondition(!verify(wrongABI)!.models[0].supports(build: 190, memory: 8 << 30))
        let empty = try signed([])
        precondition(verify(empty)?.models.isEmpty == true)
        let duplicated = try signed([entry, entry])
        precondition(verify(duplicated) == nil)
        let invalidSequence = try signed([entry], sequence: 0)
        precondition(verify(invalidSequence) == nil)
        var wrongSignature = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        wrongSignature["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let forged = try JSONSerialization.data(withJSONObject: wrongSignature)
        precondition(verify(forged) == nil)

        var files = pin["files"] as! [String: Any]
        for name in ["../escape.json", "payload.py"] {
            files[name] = ["bytes": 1, "sha256": String(repeating: "0", count: 64)]
            let unsafe = pin.merging(["files": files]) { _, new in new }
            let unsafeEnvelope = try signed([entry.merging(["pin": unsafe]) { _, new in new }])
            precondition(verify(unsafeEnvelope) == nil)
            files.removeValue(forKey: name)
        }

        let staged = PinnedModelFiles.catalogFolder(for: decoded.pin)
        let legacy = PinnedModelFiles.folder(for: decoded.pin)
        precondition(staged != legacy && staged.lastPathComponent == legacy.lastPathComponent)
        print("Catalog signature, channel, compatibility, file restrictions, and staging passed.")

        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            precondition(ModelCatalog.verify(data, channel: "beta")?.models.count == 1
                      || ModelCatalog.verify(data, channel: "production")?.models.count == 1)
        }
    }
}
