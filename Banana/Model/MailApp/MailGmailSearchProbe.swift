#if os(macOS) && !BANANA_PUBLIC
import Foundation

/// `--mail-gmail-search`: READ-ONLY. Runs each query in `BANANA_GMAIL_SEARCH_IN` through Gmail's own
/// search, via Banana's connection (the service's `/v1/mail/read`, the path Mail's Gmail search uses),
/// and writes the conversation IDs Gmail lists, in its order, to `BANANA_GMAIL_SEARCH_OUT` (0600).
/// Opens no mail store, makes no write, and exits. Input: `[{"topic":0,"query":"…","accounts":["…"]}]`.
enum MailGmailSearchProbe {
    static let argument = "--mail-gmail-search"
    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(argument) || arguments.contains(attachmentsArgument) || arguments.contains(cloudTextArgument)
    }

    private struct Task_: Decodable { let topic: Int; let query: String; let accounts: [String] }
    private struct Listing: Encodable { let threads: [String]; let estimate: Int?; let ms: Double; let error: String? }
    private struct Result: Encodable { let topic: Int; let accounts: [String]; let gmail: [String: Listing] }

    /// `--mail-gmail-attachments`: READ-ONLY. For each `{"account","message","partID","out"}` in
    /// `BANANA_GMAIL_ATTACHMENTS_IN`, reads the message (`full`) and that part's bytes through the
    /// service and writes them to `out` (0600). For measuring attachment text extraction.
    static let attachmentsArgument = "--mail-gmail-attachments"
    private struct Wanted: Decodable { let account: String; let message: String; let partID: String; let out: String }

    private static func find(_ part: GmailPart?, _ id: String) -> GmailPart? {
        guard let part else { return nil }
        if part.partId == id { return part }
        for child in part.parts ?? [] { if let hit = find(child, id) { return hit } }
        return nil
    }
    private static func bytes(_ base64url: String) -> Data? {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    private static func downloadAttachments() {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            guard let input = env["BANANA_GMAIL_ATTACHMENTS_IN"], let data = FileManager.default.contents(atPath: input),
                  let wanted = try? JSONDecoder().decode([Wanted].self, from: data) else { exit(1) }
            _ = await BananaAccount.shared.refresh()
            let access = MailCloudAccess()
            let api = GmailHTTP(cloudTransport: { path, reference, query, method, body in
                try await BananaAccount.shared.mailRequest(path: path, reference: reference, query: query, method: method, body: body)
            }, networkAllowed: { true })
            var written = 0, failed = 0
            for item in wanted {
                do {
                    let token = try await access.mailAccessToken(accountID: item.account).value
                    let message = try await MailGmailSearch.paced { try await api.message(token: token, id: item.message, format: .full) }
                    guard let part = find(message.payload, item.partID) else { failed += 1; continue }
                    var raw = part.body?.data.flatMap(bytes)
                    if raw == nil, let id = part.body?.attachmentId {
                        let body = try await MailGmailSearch.paced {
                            try await api.attachment(token: token, messageID: item.message, attachmentID: id)
                        }
                        raw = body.data.flatMap(bytes)
                    }
                    guard let raw else { failed += 1; continue }
                    PrivateReport.write(raw, toPath: item.out)
                    written += 1
                } catch { failed += 1 }
                if (written + failed) % 25 == 0 {
                    FileHandle.standardError.write(Data("\(written + failed) of \(wanted.count)\n".utf8))
                }
            }
            FileHandle.standardError.write(Data("wrote \(written), failed \(failed)\n".utf8))
            exit(0)
        }
    }

    /// `--mail-cloud-text`: READ-ONLY. For `{"account","ids":[…]}` entries in `BANANA_CLOUD_TEXT_IN`,
    /// asks Banana Cloud's bulk content (`/v1/mail/content`, no Gmail read) for the attachment text it
    /// has read, and writes `{account: {id: text}}` to `BANANA_CLOUD_TEXT_OUT` (0600).
    static let cloudTextArgument = "--mail-cloud-text"
    private struct TextWanted: Decodable { let account: String; let ids: [String] }

    private static func downloadCloudText() {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            guard let input = env["BANANA_CLOUD_TEXT_IN"], let output = env["BANANA_CLOUD_TEXT_OUT"],
                  let data = FileManager.default.contents(atPath: input),
                  let wanted = try? JSONDecoder().decode([TextWanted].self, from: data) else { exit(1) }
            _ = await BananaAccount.shared.refresh()
            let access = MailCloudAccess()
            var result: [String: [String: String]] = [:]
            var asked = 0, withText = 0, failures = 0
            for group in wanted {
                guard let reference = try? await access.mailAccessToken(accountID: group.account).value else { failures += 1; continue }
                for start in stride(from: 0, to: group.ids.count, by: 50) {
                    let batch = Array(group.ids[start..<min(start + 50, group.ids.count)])
                    var pending = batch
                    for _ in 0..<5 where !pending.isEmpty {
                        guard let body = try? JSONSerialization.data(withJSONObject: ["email": group.account.lowercased(), "ids": pending]),
                              let (answer, status) = try? await BananaAccount.shared.mailFeedRequest(kind: "content", reference: reference, body: body),
                              status == 200,
                              let json = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
                              let messages = json["messages"] as? [[String: Any]] else { failures += 1; break }
                        var later: [String] = []
                        for item in messages {
                            guard let id = item["id"] as? String else { continue }
                            if item["later"] as? Bool == true { later.append(id); continue }
                            if let parts = item["attachmentText"] as? [[String: Any]] {
                                let text = parts.map { "\($0["name"] as? String ?? "")\n\($0["text"] as? String ?? "")" }.joined(separator: "\n\n")
                                result[group.account, default: [:]][id] = text
                                withText += 1
                            }
                        }
                        pending = later
                    }
                    asked += batch.count
                    if asked % 500 < 50 { FileHandle.standardError.write(Data("\(asked) asked, \(withText) with text\n".utf8)) }
                }
            }
            if let encoded = try? JSONEncoder().encode(result) { PrivateReport.write(encoded, toPath: output) }
            FileHandle.standardError.write(Data("asked \(asked), with text \(withText), failures \(failures)\n".utf8))
            exit(0)
        }
    }

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains(cloudTextArgument) { downloadCloudText(); return }
        if ProcessInfo.processInfo.arguments.contains(attachmentsArgument) { downloadAttachments(); return }
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
