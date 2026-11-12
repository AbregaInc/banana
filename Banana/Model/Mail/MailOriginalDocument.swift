#if !BANANA_PUBLIC
import Foundation
import SwiftSoup

/// On-demand original layout using the pinned parser. Active content is removed;
/// the viewer additionally disables scripts and blocks network access by default.
enum MailOriginalDocument {
    static func prepare(_ html: String) throws -> String {
        guard html.utf8.count <= MailHTMLPreparer.maximumBytes else { throw MailHTMLPreparer.Failure.tooLarge }
        let source = try SwiftSoup.parse(html)
        var stack: [(Node, Int)] = [(source, 0)], count = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count <= 50_000, depth <= 64 else { throw MailHTMLPreparer.Failure.tooComplex }
            for child in node.getChildNodes() { stack.append((child, depth + 1)) }
        }
        let bodyRules = try Whitelist.relaxed().addTags("style")
            .addAttributes(":all", "style", "class", "id", "dir")
            .addAttributes("table", "cellpadding", "cellspacing", "border", "align", "bgcolor")
            .addAttributes("td", "align", "valign", "bgcolor", "height")
            .removeProtocols("a", "href", "ftp")
            .removeProtocols("img", "src", "http")
            .addProtocols("img", "src", "cid")
        let headRules = try Whitelist.none().addTags("style")
        let clean = try Cleaner(headWhitelist: headRules, bodyWhitelist: bodyRules).clean(source)
        for image in try clean.select("img") {
            let value = try image.attr("src")
            if value.lowercased().hasPrefix("cid:") {
                let id = String(value.dropFirst(4))
                let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                try image.attr("src", "banana-mail-image://message/" + safe)
            }
        }
        let styles = try clean.head()?.html() ?? ""
        let body = try clean.body()?.html() ?? ""
        return styles + body
    }

    static func page(_ fragment: String, remoteImages: Bool = false, embedded: Bool = false) -> String {
        let sources = (embedded ? ["banana-mail-image:"] : []) + (remoteImages ? ["https:"] : [])
        let imagePolicy = sources.isEmpty ? "'none'" : sources.joined(separator: " ")
        let margin = embedded ? 0 : 16
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(imagePolicy); font-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html{color-scheme:light}body{margin:\(margin)px;font:17px -apple-system,sans-serif;color:#1c1c1e;background:#fff;overflow-wrap:anywhere}table{max-width:100%}img{max-width:100%;height:auto}pre{white-space:pre-wrap}</style>
        </head><body>\(fragment)</body></html>
        """
    }

    static func load(stores: MailStores, id: MailMessageID) async throws -> String? {
        guard let html = try await MailBlobStore(stores: stores).content(account: id.account, messageID: id.message)?.html else { return nil }
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) { try prepare(html) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
#endif
