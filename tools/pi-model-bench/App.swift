import SwiftUI
import FoundationModels
import MLXLLM
import MLXLMCommon
import MLXFoundationModels
import MLXHuggingFace
import Tokenizers

/// A local-only inference probe. No AppleRuntimeHost, app stores, or capability executor is linked.
private struct NoDownloads: Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw NSError(domain: "PiModelBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "Remote downloads are disabled: \(id)"])
    }
}

@main
struct PiModelBenchApp: App {
    @State private var status = "Local model benchmark. Launch with --run to begin."
    var body: some Scene {
        WindowGroup {
            ScrollView { Text(status).padding().textSelection(.enabled) }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--run") else { return }
                    UIApplication.shared.isIdleTimerDisabled = true
                    await run()
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }

    @MainActor private func run() async {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
            return args[i+1]
        }
        let backend = argument("--backend", "apple")
        let runID = argument("--run-id", UUID().uuidString)
        let documents = URL.documentsDirectory
        let output = documents.appendingPathComponent("results.json")
        var report: [String: Any] = ["run":runID,"backend":backend,"device":UIDevice.current.model,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"results":[],"complete":false]
        func persist() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        persist()
        do {
            guard let resource = Bundle.main.url(forResource: "requests", withExtension: "json"),
                  let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:resource)) as? [String:Any],
                  let cases = fixture["cases"] as? [[String:Any]] else { throw CocoaError(.fileReadCorruptFile) }
            var factory: (([any FoundationModels.Tool], FoundationModels.Transcript) -> LanguageModelSession)?
            var mlx: MLXLanguageModel?
            if backend != "apple" {
                let directory = documents.appendingPathComponent("models/"+backend)
                let configuration = ModelConfiguration(directory:directory, toolCallFormat: .lfm2)
                let model = MLXLanguageModel(configuration:configuration, capabilities:[.guidedGeneration,.toolCalling],
                    weightsLocation:{ _ in directory }, load:{ config, progress in
                        try await loadModelContainer(from:NoDownloads(),using:#huggingFaceTokenizerLoader(),configuration:config,progressHandler:progress)
                    })
                let start = ContinuousClock.now
                try await model.preload()
                report["loadMilliseconds"] = milliseconds(start)
                mlx = model
                factory = { tools, transcript in LanguageModelSession(model:model, tools:tools, transcript:transcript) }
            }
            var rows: [[String:Any]] = []
            let requestedCases = argument("--cases", "").split(separator:",").map(String.init)
            let repeats = min(5,max(1,Int(argument("--repeats","2")) ?? 2))
            for repeatIndex in 0..<repeats {
                for test in cases {
                    let id = test["id"] as! String
                    if !requestedCases.isEmpty && !requestedCases.contains(id) { continue }
                    status = "\(backend): pass \(repeatIndex+1), \(id)"
                    let start = ContinuousClock.now
                    var row: [String:Any] = ["case":id,"repeat":repeatIndex]
                    do {
                        let request = String(decoding:try JSONSerialization.data(withJSONObject:test["request"]!),as:UTF8.self)
                        let raw = try await AppleFoundationModel.generate(request,makeSession:factory)
                        let parsed = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
                        row["response"] = parsed
                        row["correct"] = matches(parsed,test["expected"] as! [String:Any])
                    } catch { row["error"] = String(describing:error); row["correct"] = false }
                    row["milliseconds"] = milliseconds(start)
                    rows.append(row)
                    report["results"] = rows
                    persist()
                }
            }
            await mlx?.evict()
            report["complete"] = true
            report["correct"] = rows.filter { $0["correct"] as? Bool == true }.count
            report["total"] = rows.count
            persist()
            status = "Finished \(backend): \(report["correct"]!)/\(rows.count) correct. Results saved locally."
            print("PI_MODEL_BENCH_COMPLETE \(runID)")
        } catch {
            report["error"] = String(describing:error); report["complete"] = true; persist()
            status = "Benchmark failed: \(error)"
            print("PI_MODEL_BENCH_COMPLETE \(runID)")
        }
    }

    private func milliseconds(_ start: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to:.now).components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private func matches(_ response:[String:Any],_ expected:[String:Any]) -> Bool {
        let content = response["content"] as? [[String:Any]] ?? []
        let calls = content.filter { $0["type"] as? String == "toolCall" }
        guard let name = expected["tool"] as? String else {
            return calls.isEmpty && content.contains { ($0["text"] as? String)?.isEmpty == false }
        }
        guard calls.count == 1, calls[0]["name"] as? String == name,
              let actual = calls[0]["arguments"] as? [String:Any], let required = expected["arguments"] as? [String:Any] else { return false }
        for (key,value) in required {
            guard let actualValue = actual[key], NSDictionary(dictionary:["v":value]).isEqual(to:["v":actualValue]) else { return false }
        }
        // A food search is an explicit food name, never a nutrient or accidental prior query.
        if name == "nutrition_view", required["foodName"] == nil,
           let food = actual["foodName"] as? String, !food.isEmpty { return false }
        return true
    }
}
