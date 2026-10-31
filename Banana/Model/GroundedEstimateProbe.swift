import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `--estimate-probe`: the grounded estimate end to end on a real device — the on-device model
/// (what's used while the cloud model is off, `CloudModelGuard`), then the cloud model itself, with
/// the searchFoods tool and the bundled USDA data — written to playback.log ("🔬 probe"). Changes
/// nothing.
///
/// One step at a time, each logged before it starts: if a step brings the app down, the next launch
/// with the argument says so and goes on to the next step, so a few launches find exactly which
/// call fails. The unit tests can't run on a device (they have no host app).
@MainActor
enum GroundedEstimateProbe {
    private static let startedKey = "estimateProbe.started"
    private static let finishedKey = "estimateProbe.finished"

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--estimate-probe") else { return }
        if args.contains("--estimate-probe-reset") {
            UserDefaults.standard.removeObject(forKey: startedKey)
            UserDefaults.standard.removeObject(forKey: finishedKey)
        }
        Task { await run() }
    }

    private static func log(_ text: String) { PlaybackDiagnostics.shared.log("🔬 probe", text) }

    private static func describe(_ outcome: GroundedFoodEstimate.Outcome) {
        switch outcome {
        case .proposal(let proposal):
            log("\(proposal.name): \(Int(proposal.totals.calories)) kcal, \(proposal.items.count) items, warnings \(proposal.warnings.count)")
            for item in proposal.items {
                log("  \(item.name) · \(item.serving) · \(Int(item.macros.calories)) kcal · "
                    + (item.reference.map { "\($0.id) \($0.name)" } ?? "model's own (\(item.confidence ?? 0))"))
            }
        case .failed(let message, let detail):
            log("failed: \(message) [\(detail)]")
        case .unavailable(let message):
            log("unavailable: \(message)")
        }
    }

    private static var steps: [(String, () async -> Void)] {
        var steps: [(String, () async -> Void)] = []
        // On-device first: what the app falls back to when the cloud model is off.
        steps.append(("device item", {
            let item = await GroundedFoodEstimate.item(name: "white rice", quantity: "1 cup",
                                                       availability: .init(deviceAvailable: true))
            log("rice on device: \(item.map { "\($0.serving) · \(Int($0.macros.calories)) kcal · \($0.reference?.name ?? "model's own")" } ?? "nothing")")
        }))
        steps.append(("device meal", {
            describe(await GroundedFoodEstimate.meal(images: [], note: "chicken curry with a cup of white rice and a mango lassi",
                                                     eatenAt: Date()))
        }))
        steps.append(("device photo", {
            guard let meal = MealInboxStore.shared.items.first(where: { $0.hasPhotos }),
                  let image = MealPhotoStore.shared.image(meal.photos[0].id) else {
                log("no meal photo here to try")
                return
            }
            describe(await GroundedFoodEstimate.meal(images: [image], note: "", eatenAt: meal.eatenAt))
        }))
        #if canImport(FoundationModels)
        // Only with `--estimate-probe-cloud`: on iOS 27.0.1 these take the app down.
        if #available(iOS 27, macOS 27, *), ProcessInfo.processInfo.arguments.contains("--estimate-probe-cloud") {
            // The cloud model itself, bypassing the guard that keeps the app off it — so a later
            // OS can be checked. Each step notes the call, so a crash still teaches the guard.
            steps.append(("cloud text", {
                let answer = try? await Intelligence.guardingCloud(.cloud) {
                    try await LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                                   instructions: "Answer in one short sentence.")
                        .respond(to: "What is a banana?").content
                }
                log("cloud text: \(answer ?? "nil")")
            }))
            steps.append(("cloud tool", {
                do {
                    let part = try await Intelligence.guardingCloud(.cloud) {
                        try await LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: [FoodSearchTool()],
                                                       instructions: GroundedFoodEstimate.itemInstructions)
                            .respond(to: "1 medium banana", generating: GeneratedMealPart.self).content
                    }
                    log("cloud tool: \(part.name) \(part.grams) g id '\(part.foodID)'")
                } catch { log("cloud tool threw: \(error)") }
            }))
        }
        #endif
        return steps
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(8))   // after launch has settled
        log("availability \(Intelligence.current)")
        var finished = Set(UserDefaults.standard.stringArray(forKey: finishedKey) ?? [])
        if let crashed = UserDefaults.standard.string(forKey: startedKey), !finished.contains(crashed) {
            log("step '\(crashed)' never finished last time (the app went down in it); skipping it")
            finished.insert(crashed)
            UserDefaults.standard.set(Array(finished), forKey: finishedKey)
        }
        for (name, step) in steps where !finished.contains(name) {
            log("step '\(name)' starting")
            UserDefaults.standard.set(name, forKey: startedKey)
            UserDefaults.standard.synchronize()
            let started = Date()
            await step()
            finished.insert(name)
            UserDefaults.standard.set(Array(finished), forKey: finishedKey)
            log("step '\(name)' done in \(Int(Date().timeIntervalSince(started)))s")
        }
        log("all steps done")
    }
}
