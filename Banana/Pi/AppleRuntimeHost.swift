import Foundation
import JavaScriptCore
import Security
import SQLite3
import FoundationModels

@MainActor
private final class HostTimer: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func fire() { callback() }
}

private struct DatabaseFailure: LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { message }
}

/// Native database operations only. Pi's portable SqliteStorage retains its schema and commit/recovery implementation.
private final class HostDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot allocate SQLite handle"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw DatabaseFailure(code: status, message: message)
        }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000")
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else { throw failure(status) }
        self.handle = nil
    }

    private func failure(_ code: Int32) -> DatabaseFailure {
        DatabaseFailure(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite database is closed")
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw failure(SQLITE_MISUSE) }
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure(status) }
    }

    func query(_ sql: String, parameters: String, mode: String) throws -> [[String: Any]] {
        guard let handle else { throw failure(SQLITE_MISUSE) }
        if mode == "exec" { try execute(sql); return [] }
        guard let values = try JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [[String: Any]] else {
            throw DatabaseFailure(code: SQLITE_MISMATCH, message: "Invalid SQLite parameters")
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure(prepared) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else {
            throw DatabaseFailure(code: SQLITE_RANGE, message: "Incorrect SQLite parameter count")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value["type"] as? String {
            case "null": status = sqlite3_bind_null(statement, index)
            case "integer":
                guard let text = value["value"] as? String, let integer = Int64(text) else {
                    throw DatabaseFailure(code: SQLITE_RANGE, message: "SQLite integer outside signed 64-bit range")
                }
                status = sqlite3_bind_int64(statement, index, integer)
            case "real":
                guard let real = value["value"] as? Double, real.isFinite else {
                    throw DatabaseFailure(code: SQLITE_MISMATCH, message: "Invalid SQLite number")
                }
                status = sqlite3_bind_double(statement, index, real)
            case "text":
                guard let text = value["value"] as? String else { throw failure(SQLITE_MISMATCH) }
                status = text.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, Int32(text.utf8.count), transient)
                }
            case "blob":
                guard let bytes = value["value"] as? [UInt8] else { throw failure(SQLITE_MISMATCH) }
                if bytes.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) }
                else { status = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
            default: throw DatabaseFailure(code: SQLITE_MISMATCH, message: "Unsupported SQLite binding")
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        var rows: [[String: Any]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: row[key] = ["type": "null"]
                case SQLITE_INTEGER: row[key] = ["type": "integer", "value": String(sqlite3_column_int64(statement, index))]
                case SQLITE_FLOAT: row[key] = ["type": "real", "value": sqlite3_column_double(statement, index)]
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    let text = String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, index), count: count), as: UTF8.self)
                    row[key] = ["type": "text", "value": text]
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    let bytes = count == 0 ? [] : Array(UnsafeBufferPointer(start: sqlite3_column_blob(statement, index)?.assumingMemoryBound(to: UInt8.self), count: count))
                    row[key] = ["type": "blob", "value": bytes]
                default: throw failure(SQLITE_MISMATCH)
                }
            }
            rows.append(row)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure(status) }
        return rows
    }
}

@MainActor
final class AppleRuntimeHost {
    let context: JSContext
    var resources: [String: Int] { ["databases": databases.count, "timers": timers.count, "modelRequests": modelRequests.count] }
    var toolHandler: ((String) async throws -> String)?
    var modelHandler: ((String) async throws -> String)?
    var modelStatusHandler: (() -> [String: Any])?
    var eventHandler: ((String) -> Void)?
    private var toolRequests: [Int: Task<Void, Never>] = [:]
    private var commandReplies: [Int: (String, Bool) -> Void] = [:]
    private var commandID = 0
    private var databases: [Int: HostDatabase] = [:]
    private var databaseID = 0
    private var timers: [Int: Timer] = [:]
    private var timerID = 0
    private var reportedErrors: [String] = []
    private var modelRequests: [Int: Task<Void, Never>] = [:]
    private var modelRequestID = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private var ended = false
    var isStopped: Bool { ended }
    private let completion: (String, Bool) -> Void

    init(databasePath: String, completion: @escaping (String, Bool) -> Void) throws {
        guard let context = JSContext() else { throw DatabaseFailure(code: 0, message: "Cannot create JavaScriptCore context") }
        self.context = context
        self.completion = completion
        install(databasePath: databasePath)
    }

    private func envelope(_ operation: () throws -> Any) -> String {
        let result: [String: Any]
        do { result = ["ok": true, "value": try operation()] }
        catch let error as DatabaseFailure { result = ["ok": false, "error": ["code": error.code, "message": error.message]] }
        catch { result = ["ok": false, "error": ["code": 0, "message": String(describing: error)]] }
        do { return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self) }
        catch { return "{\"ok\":false,\"error\":{\"code\":0,\"message\":\"Host JSON encoding failed\"}}" }
    }

    private func install(databasePath: String) {
        let log: @convention(block) (String) -> Void = { print($0) }
        let report: @convention(block) (String) -> Void = { [weak self] error in self?.reportedErrors.append(error); print("Pi host error: \(error)") }
        let errors: @convention(block) () -> String = { [weak self] in
            String(decoding: (try? JSONEncoder().encode(self?.reportedErrors ?? [])) ?? Data("[]".utf8), as: UTF8.self)
        }
        let monotonic: @convention(block) () -> Double = { [weak self] in
            guard let self else { return 0 }
            return Double(DispatchTime.now().uptimeNanoseconds - self.started) / 1_000_000
        }
        let random: @convention(block) (Int) -> String = { count in
            guard count >= 0, count <= 65536 else { return "{\"error\":\"Invalid random byte count\"}" }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return "{\"error\":\"Secure random failed\"}" }
            return String(decoding: (try? JSONEncoder().encode(bytes)) ?? Data("[]".utf8), as: UTF8.self)
        }
        let open: @convention(block) (String) -> String = { [weak self] path in
            guard let self else { return "{}" }
            return self.envelope { self.databaseID += 1; self.databases[self.databaseID] = try HostDatabase(path: path); return self.databaseID }
        }
        let query: @convention(block) (Int, String, String, String) -> String = { [weak self] id, sql, parameters, mode in
            guard let self else { return "{}" }
            return self.envelope {
                guard let database = self.databases[id] else { throw DatabaseFailure(code: SQLITE_MISUSE, message: "SQLite database is closed") }
                return try database.query(sql, parameters: parameters, mode: mode)
            }
        }
        let close: @convention(block) (Int) -> String = { [weak self] id in
            guard let self else { return "{}" }
            return self.envelope { try self.databases[id]?.close(); self.databases.removeValue(forKey: id); return NSNull() }
        }
        let timer: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, milliseconds in
            guard let self, !self.ended else { return 0 }
            self.timerID += 1
            let id = self.timerID
            let target = HostTimer { [weak self] in
                guard let self, !self.ended else { return }
                self.timers.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
            self.timers[id] = Timer.scheduledTimer(timeInterval: max(milliseconds / 1000, 0.0001), target: target,
                                                 selector: #selector(HostTimer.fire), userInfo: nil, repeats: false)
            return id
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.invalidate() }
        let done: @convention(block) (String, Bool) -> Void = { [weak self] text, passed in self?.finish(text, passed: passed) }
        let publishWake: @convention(block) (String) -> String = { [weak self] json in
            guard let self else { return "{}" }
            return self.envelope {
                let data = Data(json.utf8)
                guard let wake = try JSONSerialization.jsonObject(with: data) as? [String: Any], wake["active"] is Bool else {
                    throw DatabaseFailure(code: 0, message: "Invalid Pi wake hint")
                }
                try data.write(to: URL(fileURLWithPath: databasePath + ".wake.json"), options: .atomic)
                return true
            }
        }
        let readWake: @convention(block) () -> String = { [weak self] in
            guard let self else { return "{}" }
            return self.envelope {
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: databasePath + ".wake.json")))
            }
        }
        let hostResources: @convention(block) () -> String = { [weak self] in
            guard let self else { return "{}" }
            return self.envelope { ["databases": self.databases.count, "timers": self.timers.count, "modelRequests": self.modelRequests.count] }
        }
        let modelStatus: @convention(block) () -> String = { [weak self] in
            String(decoding: (try? JSONSerialization.data(withJSONObject: self?.modelStatusHandler?() ?? AppleFoundationModel.availability())) ?? Data("{}".utf8), as: UTF8.self)
        }
        let modelSchema: @convention(block) (String) -> String = { [weak self] json in
            guard let self else { return "{}" }
            return self.envelope {
                guard let schema = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    throw DatabaseFailure(code: 0, message: "Invalid schema object")
                }
                _ = try GenerationSchema(root: AppleFoundationModel.schema(schema, name: "contract"), dependencies: [])
                return true
            }
        }
        let modelStart: @convention(block) (String, JSValue) -> Int = { [weak self] request, callback in
            guard let self, !self.ended else { return 0 }
            self.modelRequestID += 1
            let id = self.modelRequestID
            self.modelRequests[id] = Task { [weak self] in
                let result: String
                do {
                    let generated: String
                    if let handler = self?.modelHandler { generated = try await handler(request) }
                    else { generated = try await AppleFoundationModel.generate(request) }
                    result = "{\"ok\":true,\"value\":" + generated + "}"
                }
                catch {
                    let error: [String: Any] = ["ok": false, "error": ["code": "native-model", "message": String(describing: error)]]
                    result = String(decoding: (try? JSONSerialization.data(withJSONObject: error)) ?? Data("{}".utf8), as: UTF8.self)
                }
                guard let self else { return }
                self.modelRequests.removeValue(forKey: id)
                guard !self.ended, !Task.isCancelled else { return }
                callback.call(withArguments: [result])
            }
            return id
        }
        let modelCancel: @convention(block) (Int) -> Void = { [weak self] id in self?.modelRequests.removeValue(forKey: id)?.cancel() }
        let toolStart: @convention(block) (String, JSValue) -> Int = { [weak self] request, callback in
            guard let self, !self.ended else { return 0 }
            self.modelRequestID += 1
            let id = self.modelRequestID
            self.toolRequests[id] = Task { [weak self] in
                guard let self else { return }
                let result: String
                do {
                    try Task.checkCancellation()
                    guard let handler = self.toolHandler else { throw DatabaseFailure(code: 0, message: "Banana tools are unavailable") }
                    result = "{\"ok\":true,\"value\":" + (try await handler(request)) + "}"
                } catch {
                    result = self.envelope { throw error }
                }
                self.toolRequests.removeValue(forKey: id)
                guard !self.ended, !Task.isCancelled else { return }
                callback.call(withArguments: [result])
            }
            return id
        }
        let toolCancel: @convention(block) (Int) -> Void = { [weak self] id in self?.toolRequests.removeValue(forKey: id)?.cancel() }
        let currentClock: @convention(block) () -> String = {
            let now = Date()
            let zone = TimeZone.autoupdatingCurrent
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            let value: [String: Any] = ["date": formatter.string(from: now),
                "instant": now.ISO8601Format(), "timeZone": zone.identifier,
                "utcOffsetSeconds": zone.secondsFromGMT(for: now)]
            return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        let agentEvent: @convention(block) (String) -> Void = { [weak self] event in self?.eventHandler?(event) }
        for (name, value) in ["nativeLog": log as Any, "nativeReportError": report, "nativeReportedErrors": errors,
                              "nativeMonotonicMilliseconds": monotonic, "nativeRandom": random,
                              "nativeDatabaseOpen": open, "nativeDatabaseQuery": query, "nativeDatabaseClose": close,
                              "nativeSetTimeout": timer, "nativeClearTimeout": clear, "nativeDone": done,
                              "nativeModelStatus": modelStatus, "nativeModelStart": modelStart, "nativeModelCancel": modelCancel,
                              "nativeModelValidateSchema": modelSchema, "nativePublishWake": publishWake,
                              "nativeReadWake": readWake, "nativeHostResources": hostResources,
                              "nativeCurrentClock": currentClock, "nativeToolStart": toolStart, "nativeToolCancel": toolCancel, "nativeAgentEvent": agentEvent] {
            context.setObject(value, forKeyedSubscript: name as NSString)
        }
        context.setObject(databasePath, forKeyedSubscript: "nativeDatabasePath" as NSString)
        context.exceptionHandler = { [weak self] _, error in
            self?.finish("JavaScript exception: \(error?.toString() ?? "unknown")\n\(error?.forProperty("stack")?.toString() ?? "")", passed: false)
        }
    }

    func start(sourceDirectory: URL, bundleURL: URL, runProof: Bool = true) throws {
        context.evaluateScript(try String(contentsOf: sourceDirectory.appendingPathComponent("bootstrap.js"), encoding: .utf8))
        if !ended { context.evaluateScript(try String(contentsOf: bundleURL, encoding: .utf8)) }
        if !ended && runProof { context.evaluateScript("runPiSmoke().then(r => nativeDone(JSON.stringify(r), r.passed), e => nativeDone(String(e) + '\\n' + e.stack, false))") }
    }

    func load(bootstrap: URL, script: URL) throws {
        context.evaluateScript(try String(contentsOf: bootstrap, encoding: .utf8))
        if !ended { context.evaluateScript(try String(contentsOf: script, encoding: .utf8)) }
        if ended { throw DatabaseFailure(code: 0, message: "The assistant could not start.") }
    }

    func setForeground(_ active: Bool, completion: @escaping (String, Bool) -> Void) {
        guard !ended else { completion("Pi runtime is stopped", false); return }
        guard let function = context.objectForKeyedSubscript("piSetForeground"), !function.isUndefined else {
            completion("", true)
            return
        }
        let done: @convention(block) (String, Bool) -> Void = completion
        function.call(withArguments: [active, done])
    }

    func request(_ operation: String, payload: String = "{}") async throws -> String {
        guard !ended, let function = context.objectForKeyedSubscript("bananaAgentCommand"), !function.isUndefined else {
            throw DatabaseFailure(code: 0, message: "The assistant runtime is unavailable")
        }
        commandID += 1
        let id = commandID
        return try await withCheckedThrowingContinuation { continuation in
            commandReplies[id] = { result, passed in
                if passed { continuation.resume(returning: result) }
                else { continuation.resume(throwing: DatabaseFailure(code: 0, message: result)) }
            }
            let reply: @convention(block) (String, Bool) -> Void = { [weak self] result, passed in
                self?.commandReplies.removeValue(forKey: id)?(result, passed)
            }
            function.call(withArguments: [operation, payload, reply])
        }
    }

    private func cancelNativeWork() {
        for request in modelRequests.values { request.cancel() }
        modelRequests.removeAll()
        for request in toolRequests.values { request.cancel() }
        toolRequests.removeAll()
        let replies = Array(commandReplies.values)
        commandReplies.removeAll()
        for reply in replies { reply("The assistant runtime stopped", false) }
    }

    private func finish(_ text: String, passed: Bool) {
        guard !ended else { return }
        ended = true
        cancelNativeWork()
        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
        completion(text, passed)
    }

    func stop() {
        ended = true
        cancelNativeWork()
        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
        for database in databases.values { try? database.close() }
        databases.removeAll()
    }
}
