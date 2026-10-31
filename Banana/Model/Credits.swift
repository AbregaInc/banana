import Foundation

/// What Banana builds on, as Settings shows it. The same list as `NOTICE.md`: a test holds the
/// two together.
enum Credits {
    struct Entry: Identifiable {
        let title: String
        let url: URL
        var id: URL { url }

        init(_ title: String, _ url: String) {
            self.title = title
            self.url = URL(string: url)!
        }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Storage and HTML", entries: [
            Entry("GRDB.swift · Gwendal Roué · MIT", "https://github.com/groue/GRDB.swift"),
            Entry("SwiftSoup · Jonathan Hedley and Nabil Chatbi · MIT", "https://github.com/scinfu/SwiftSoup"),
        ]),
        Group(title: "Transcription", entries: [
            Entry("Parakeet TDT v3 · NVIDIA · CC BY 4.0", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
            Entry("FluidAudio · Apache 2.0", "https://github.com/FluidInference/FluidAudio"),
        ]),
        Group(title: "Narrator voices", entries: [
            Entry("voice-gender-classifier · Jaesung Huh · MIT", "https://huggingface.co/JaesungHuh/voice-gender-classifier"),
        ]),
        Group(title: "Food and supplements", entries: [
            Entry("USDA FoodData Central · public domain", "https://fdc.nal.usda.gov/download-datasets/"),
            Entry("© Open Food Facts contributors · ODbL", "https://openfoodfacts.org"),
            Entry("Dietary Supplement Label Database · NIH · public domain", "https://dsld.od.nih.gov"),
            Entry("RxNorm · NLM · public domain", "https://www.nlm.nih.gov/research/umls/rxnorm/"),
        ]),
        Group(title: "Airports", entries: [
            Entry("OurAirports · public domain", "https://ourairports.com/data/"),
            Entry("mwgg/Airports · MIT", "https://github.com/mwgg/Airports"),
        ]),
        Group(title: "Weather", entries: [
            Entry("Apple Weather · data sources", "https://developer.apple.com/weatherkit/data-source-attribution/"),
        ]),
        Group(title: "Google sign-in", entries: [
            Entry("GoogleSignIn · Apache 2.0", "https://github.com/google/GoogleSignIn-iOS"),
            Entry("AppAuth · Apache 2.0", "https://github.com/openid/AppAuth-iOS"),
            Entry("GTMAppAuth · Apache 2.0", "https://github.com/google/GTMAppAuth"),
            Entry("gtm-session-fetcher · Apache 2.0", "https://github.com/google/gtm-session-fetcher"),
            Entry("GoogleUtilities · Apache 2.0", "https://github.com/google/GoogleUtilities"),
            Entry("app-check · Apache 2.0", "https://github.com/google/app-check"),
            Entry("interop-ios-for-google-sdks · Apache 2.0", "https://github.com/google/interop-ios-for-google-sdks"),
            Entry("promises · Apache 2.0", "https://github.com/google/promises"),
        ]),
    ]
}
