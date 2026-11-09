import XCTest

/// A module's code compiles only into a build that carries it (BANANA_MODULES), and so do the
/// frameworks, permission requests and type names that come with it (Config/Modules.json).
///
/// A module's files are wrapped whole in its condition (`#if BANANA_MODULE_PODCASTS` … `#endif`,
/// or `#if !BANANA_PUBLIC` for Email). What a build leaves out is then checked three ways:
/// the artifact (tools/check-release.sh), the build of the App Store flavour itself, and these
/// tests, which read the sources and name the file that breaks a rule:
/// - every whole-file wrapper holds the whole file (as `MailTestingFenceTests` asks of fixtures);
/// - a file that imports a framework a module brings is fenced to that module;
/// - a file that asks for a permission whose usage string a module brings is fenced to it, so no
///   build can ask for a permission its Info.plist has no string for;
/// - the type names the release check looks for are defined only in their module's files.
final class ModuleFenceTests: XCTestCase {

    private struct Module {
        var name: String
        var condition: String
        var frameworks: [String]
        var info: [String]
        var markers: [String]
    }

    /// The modules of Config/Modules.json.
    private func modules() throws -> [Module] {
        let url = SourceTree.root.appendingPathComponent("Config/Modules.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "the source tree is not on this machine")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try XCTUnwrap(json["modules"] as? [String: [String: Any]])
        return entries.map { name, entry in
            Module(name: name, condition: entry["condition"] as? String ?? "",
                   frameworks: entry["frameworks"] as? [String] ?? [],
                   info: entry["info"] as? [String] ?? [],
                   markers: entry["markers"] as? [String] ?? [])
        }.sorted { $0.name < $1.name }
    }

    /// Every Swift file the app targets compile.
    private func appSources() throws -> [(path: String, text: String)] {
        var files: [(String, String)] = []
        for folder in ["Banana", "Shared", "BananaMac", "BananaWidget"] {
            let root = SourceTree.root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                files.append((folder + url.path.dropFirst(root.path.count), try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    // MARK: - The modules and the code agree

    func testEveryModuleHasItsConditionAndCapabilities() throws {
        let listed = try modules()
        XCTAssertEqual(Set(listed.map(\.name)), Set(AppModule.allCases.map(\.rawValue)))
        for module in AppModule.allCases {
            XCTAssertEqual(listed.first { $0.name == module.rawValue }?.condition, module.compileCondition)
        }
    }

    // MARK: - Whole-file wrappers

    /// A file that starts with a module's condition holds all of itself inside it: no `#else`,
    /// nothing after its `#endif`.
    func testAModuleWrapperHoldsItsWholeFile() throws {
        let conditions = try modules().map(\.condition) + ["!BANANA_PUBLIC"]
        var problems: [String] = []
        for (path, text) in try appSources() {
            guard let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init),
                  first.hasPrefix("#if ") else { continue }
            // A module wrapper: a condition made of module conditions alone. A file that starts
            // with `#if DEBUG && os(macOS) && !BANANA_PUBLIC` and has a section for each build is not one.
            var rest = String(first.dropFirst(4))
            for condition in conditions { rest = rest.replacingOccurrences(of: condition, with: "") }
            guard rest.allSatisfy({ " |&()".contains($0) }) else { continue }
            if let problem = Self.wrapperProblem(text) { problems.append("\(path): \(problem)") }
        }
        XCTAssertEqual(problems, [])
    }

    /// The fence test's rule, for one file: the first line's `#if` closes on the last line, with no
    /// other branch at its level.
    static func wrapperProblem(_ text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard lines.last == "#endif" else { return "the last line is not `#endif`" }
        var depth = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") { depth += 1 }
            else if trimmed.hasPrefix("#endif") { depth -= 1 }
            else if (trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif")) && depth == 1 {
                return "another branch on line \(index + 1)"
            }
            if depth == 0 && index < lines.count - 1 { return "the wrapper closes on line \(index + 1)" }
        }
        return depth == 0 ? nil : "an `#if` is never closed"
    }

    func testTheWrapperRuleRefusesAPartialWrapper() {
        XCTAssertNil(Self.wrapperProblem("#if BANANA_MODULE_FOOD\nimport Foundation\n#endif\n"))
        XCTAssertNotNil(Self.wrapperProblem("#if BANANA_MODULE_FOOD\nlet a = 1\n#else\nlet a = 2\n#endif\n"))
        XCTAssertNotNil(Self.wrapperProblem("#if BANANA_MODULE_FOOD\nlet a = 1\n#endif\nlet b = 2\n"))
    }

    // MARK: - What compiles where

    /// Whether `text` compiles into a build that carries none of `owners`: its whole-file
    /// wrappers (the first lines' `#if`s, each closing on the last line) all hold with those
    /// modules off. Any other condition (`os(iOS)`, `DEBUG`) counts as possibly true.
    private func compiles(_ text: String, without owners: Set<String>, conditions: [String: String]) -> Bool {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var off = Set<String>()
        for owner in owners { if let condition = conditions[owner] { off.insert(condition) } }
        while let first = lines.first, first.hasPrefix("#if "), Self.wrapperProblem(lines.joined(separator: "\n")) == nil {
            // Email's code is fenced by its older switch: BANANA_PUBLIC is set exactly when Email is off.
            let condition = String(first.dropFirst(4)).replacingOccurrences(of: "!BANANA_PUBLIC", with: "BANANA_MODULE_EMAIL")
            if !ConditionEvaluator.holds(condition, off: off) { return false }
            lines = Array(lines.dropFirst())
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.removeLast()
        }
        return true
    }

    /// A framework a module brings is imported only by code that leaves with it: the release
    /// check refuses an artifact that links it, and some (HealthKit, Photos, Speech) are what
    /// App Store Connect reads to ask for usage strings.
    func testAModulesFrameworksAreImportedOnlyByItsCode() throws {
        let all = try modules()
        let conditions = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.condition) })
        var owners: [String: Set<String>] = [:]
        for module in all { for framework in module.frameworks { owners[framework, default: []].insert(module.name) } }
        var problems: [String] = []
        for (path, text) in try appSources() {
            for (framework, names) in owners where text.contains("import \(framework)\n") {
                if compiles(text, without: names, conditions: conditions) {
                    problems.append("\(path) imports \(framework) outside \(names.sorted())")
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// No build asks for a permission whose usage string it leaves out: each call that brings up
    /// a system permission question is in code fenced to the modules that bring its string.
    func testNoBuildAsksForAPermissionItHasNoStringFor() throws {
        let all = try modules()
        let conditions = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.condition) })
        var owners: [String: Set<String>] = [:]
        for module in all { for key in module.info { owners[key, default: []].insert(module.name) } }
        // What asks, and the string it needs.
        let asks: [(call: String, key: String)] = [
            ("HKHealthStore()", "NSHealthShareUsageDescription"),
            ("requestAuthorization(toShare", "NSHealthShareUsageDescription"),
            ("PHPhotoLibrary.requestAuthorization", "NSPhotoLibraryUsageDescription"),
            ("AVCaptureDevice.requestAccess", "NSCameraUsageDescription"),
            ("DataScannerViewController", "NSCameraUsageDescription"),
            ("SFSpeechRecognizer.requestAuthorization", "NSSpeechRecognitionUsageDescription"),
            ("requestRecordPermission", "NSMicrophoneUsageDescription"),
            ("MusicAuthorization.request", "NSAppleMusicUsageDescription"),
            ("MPMediaLibrary.requestAuthorization", "NSAppleMusicUsageDescription"),
            ("NWBrowser(", "NSLocalNetworkUsageDescription"),
        ]
        var problems: [String] = []
        for (path, text) in try appSources() {
            for ask in asks where text.contains(ask.call) {
                guard let names = owners[ask.key] else { continue }   // the core's string: every build has it
                if compiles(text, without: names, conditions: conditions) {
                    problems.append("\(path) calls \(ask.call), which needs \(ask.key) (\(names.sorted()))")
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// The type names tools/check-release.sh looks for in a build without the module are defined
    /// only in that module's code, or the check would refuse a build that is fine (or the name
    /// would stop meaning anything).
    func testTheReleaseCheckMarkersAreTheModulesOwn() throws {
        let all = try modules()
        let conditions = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.condition) })
        let sources = try appSources()
        var problems: [String] = []
        for module in all {
            for marker in module.markers where marker.allSatisfy({ $0.isLetter || $0.isNumber }) {
                let declarations = sources.filter { _, text in
                    ["class", "struct", "enum", "actor"].contains { text.contains("\($0) \(marker) ") || text.contains("\($0) \(marker):") || text.contains("\($0) \(marker){") }
                }
                if declarations.isEmpty { problems.append("\(marker) (\(module.name)) is declared nowhere") }
                for (path, text) in declarations where compiles(text, without: [module.name], conditions: conditions) {
                    problems.append("\(marker) is declared in \(path), outside \(module.name)")
                }
            }
        }
        XCTAssertEqual(problems, [])
    }
}

/// `#if` conditions with some names known false: `!`, `&&`, `||`, parentheses; a name not known
/// false, and any `os(…)`-style test, may be true.
enum ConditionEvaluator {
    static func holds(_ condition: String, off: Set<String>) -> Bool {
        var parser = Parser(tokens: tokens(condition), off: off)
        return parser.or() != .no
    }

    private enum Truth { case yes, no, maybe }

    private static func tokens(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        var chars = Array(text)
        var index = 0
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        while index < chars.count {
            let c = chars[index]
            if c == "(" && !word.isEmpty {
                // A call such as os(iOS): one token, whatever it says.
                var depth = 0
                while index < chars.count {
                    word.append(chars[index])
                    if chars[index] == "(" { depth += 1 } else if chars[index] == ")" { depth -= 1; if depth == 0 { break } }
                    index += 1
                }
                out.append("?"); word = ""
            } else if c == "&" || c == "|" {
                flush()
                if index + 1 < chars.count, chars[index + 1] == c { out.append(String([c, c])); index += 1 }
            } else if c == "!" || c == "(" || c == ")" {
                flush(); out.append(String(c))
            } else if c.isWhitespace {
                flush()
            } else {
                word.append(c)
            }
            index += 1
        }
        flush()
        chars = []
        return out
    }

    private struct Parser {
        var tokens: [String]
        let off: Set<String>
        var position = 0

        mutating func next() -> String? { position < tokens.count ? tokens[position] : nil }

        mutating func or() -> Truth {
            var left = and()
            while next() == "||" { position += 1; let right = and(); left = left == .yes || right == .yes ? .yes : (left == .no && right == .no ? .no : .maybe) }
            return left
        }
        mutating func and() -> Truth {
            var left = unary()
            while next() == "&&" { position += 1; let right = unary(); left = left == .no || right == .no ? .no : (left == .yes && right == .yes ? .yes : .maybe) }
            return left
        }
        mutating func unary() -> Truth {
            if next() == "!" {
                position += 1
                switch unary() { case .yes: return .no; case .no: return .yes; case .maybe: return .maybe }
            }
            if next() == "(" {
                position += 1
                let value = or()
                if next() == ")" { position += 1 }
                return value
            }
            let word = next() ?? "?"
            position += 1
            return off.contains(word) ? .no : .maybe
        }
    }
}
