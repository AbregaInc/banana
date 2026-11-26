#if os(macOS) && !BANANA_PUBLIC
import Foundation

/// `--mail-gmail-search`: READ-ONLY. Runs each query in `BANANA_GMAIL_SEARCH_IN` through Gmail's own
/// search, via Banana's connection (the service's `/v1/mail/read`, the path Mail's Gmail search uses),
/// and writes the conversation IDs Gmail lists, in its order, to `BANANA_GMAIL_SEARCH_OUT` (0600).
/// Opens no mail store, makes no write, and exits. Input: `[{"topic":0,"query":"…","accounts":["…"]}]`.
enum MailGmailSearchProbe {
    static let argument = "--mail-gmail-search"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private struct Task_: Decodable { let topic: Int; let query: String; let accounts: [String] }
    private struct Listing: Encodable { let threads: [String]; let estimate: Int?; let ms: Double; let error: String? }
    private struct Result: Encodable { let topic: Int; let accounts: [String]; let gmail: [String: Listing] }

    static func runIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            guard let input = env["BANANA_GMAIL_SEARCH_IN"], let output = env["BANANA_GMAIL_SEARCH_OUT"],
                  let data = FileManager.default.contents(atPath: input),
                  let tasks = try? JSONDecoder().decode([Task_].self, from: data) else {
                FileHandle.standardError.write(Data("missing or unreadable BANANA_GMAIL_SEARCH_IN/OUT\n".utf8))
                exit(1)
            }
            _ = await BananaAccount.shared.refresh()
            let access = MailCloudAccess()
            let api = GmailHTTP(cloudTransport: { path, reference, query, method, body in
                try await BananaAccount.shared.mailRequest(path: path, reference: reference, query: query, method: method, body: body)
            }, networkAllowed: { true })
            var tokens: [String: String] = [:]
            for account in Set(tasks.flatMap(\.accounts)) {
                if let token = try? await access.mailAccessToken(accountID: account) { tokens[account] = token.value }
            }
            FileHandle.standardError.write(Data("reachable accounts: \(tokens.count) of \(Set(tasks.flatMap(\.accounts)).count)\n".utf8))
            var results: [Result] = []
            for task in tasks {
                var per: [String: Listing] = [:]
                for account in task.accounts {
                    guard let token = tokens[account] else {
                        per[account] = Listing(threads: [], estimate: nil, ms: 0, error: "no access"); continue
                    }
                    var threads: [String] = [], seen = Set<String>(), cursor: String?, estimate: Int?, failure: String?
                    let start = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<3 {
                        do {
                            let page = try await MailGmailSearch.paced {
                                try await api.listMessages(token: token, labelIDs: [], query: task.query,
                                                           includeSpamTrash: false, pageToken: cursor, maxResults: 100)
                            }
                            if estimate == nil { estimate = page.resultSizeEstimate }
                            for reference in page.messages ?? [] {
                                if let thread = reference.threadId, seen.insert(thread).inserted { threads.append(thread) }
                            }
                            cursor = page.nextPageToken
                        } catch { failure = String(describing: type(of: error)) + ": " + String(describing: error); break }
                        if threads.count >= 50 || cursor?.isEmpty != false { break }
                    }
                    per[account] = Listing(threads: Array(threads.prefix(50)), estimate: estimate,
                                           ms: (ProcessInfo.processInfo.systemUptime - start) * 1000, error: failure)
                }
                results.append(Result(topic: task.topic, accounts: task.accounts, gmail: per))
                if results.count % 25 == 0 {
                    FileHandle.standardError.write(Data("\(results.count) of \(tasks.count)\n".utf8))
                    if let partial = try? JSONEncoder().encode(results) { PrivateReport.write(partial, toPath: output) }
                }
            }
            if let encoded = try? JSONEncoder().encode(results) { PrivateReport.write(encoded, toPath: output) }
            FileHandle.standardError.write(Data("wrote \(results.count) topics\n".utf8))
            exit(0)
        }
    }
}
#endif
