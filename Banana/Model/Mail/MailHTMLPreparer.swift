#if !BANANA_PUBLIC
import Foundation
import SwiftSoup

struct MailPreparedBody: Codable, Equatable, Sendable {
    var version: Int
    var text: MailText
    /// Inert fragment retained for the designed reader. Never load original HTML into a view.
    var safeHTML: String?
    var shownAsText: Bool

    var body: MailBody { .text(text, quoteStartsAt: nil, notices: shownAsText ? [.shownAsText] : []) }
}

/// Runs on the preparation worker, before opening. Uses the pinned library's parser and cleaner.
enum MailHTMLPreparer {
    static let version = 1
    static let maximumBytes = 2 * 1024 * 1024
    enum Failure: Error { case tooLarge, tooComplex }

    static func prepare(plain: String?, html: String?, measure: ((String, Double) -> Void)? = nil) throws -> MailPreparedBody {
        var previous = measure == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        func mark(_ phase: String) {
            guard let measure else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            measure(phase, Double(now - previous) / 1_000_000)
            previous = now
        }
        if let html {
            guard html.utf8.count <= maximumBytes else { throw Failure.tooLarge }
            let source = try SwiftSoup.parseBodyFragment(html)
            mark("parse")
            // Bound subsequent walks independently of the parser's input-size bound.
            var stack: [(Node, Int)] = [(source, 0)], nodes = 0
            while let (node, depth) = stack.popLast() {
                nodes += 1
                guard nodes <= 50_000, depth <= 64 else { throw Failure.tooComplex }
                for child in node.getChildNodes() { stack.append((child, depth + 1)) }
            }
            mark("bounds")
            let whitelist = try Whitelist.relaxed().removeTags("img")
                .removeProtocols("a", "href", "ftp")
                .removeAttributes("blockquote", "cite").removeAttributes("q", "cite")
                .removeAttributes("col", "width").removeAttributes("colgroup", "width")
                .removeAttributes("table", "width").removeAttributes("td", "width").removeAttributes("th", "width")
            let clean = try Cleaner(headWhitelist: nil, bodyWhitelist: whitelist).clean(source)
            mark("clean")
            guard let body = clean.body() else { return plainBody(plain ?? "", shownAsText: true) }
            let safe = try body.html()
            guard safe.utf8.count <= maximumBytes else { throw Failure.tooLarge }
            mark("serialize")
            let native = try nativeText(body)
            mark("nativeText")
            return MailPreparedBody(version: version, text: native, safeHTML: safe, shownAsText: true)
        }
        guard (plain?.utf8.count ?? 0) <= maximumBytes else { throw Failure.tooLarge }
        return plainBody(plain ?? "", shownAsText: false)
    }

    private static func plainBody(_ value: String, shownAsText: Bool) -> MailPreparedBody {
        MailPreparedBody(version: version, text: MailText(blocks: [MailTextBlock(kind: .preformatted,
            runs: [MailTextRun(text: value.replacingOccurrences(of: "\0", with: ""), link: nil)])]),
            safeHTML: nil, shownAsText: shownAsText)
    }

    private static func nativeText(_ root: Element) throws -> MailText {
        var blocks: [MailTextBlock] = [], runs: [MailTextRun] = []
        var kind = MailTextBlock.Kind.paragraph
        let blockTags: Set<String> = ["p", "div", "blockquote", "li", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "tr"]
        func flush() {
            if !runs.isEmpty && runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                blocks.append(MailTextBlock(kind: kind, runs: runs))
            }
            runs.removeAll(keepingCapacity: true)
        }
        func walk(_ node: Node, style: MailTextStyle, link: URL?, quote: Int, pre: Bool) throws {
            if let text = node as? TextNode {
                let value = (pre ? text.getWholeText() : text.text()).replacingOccurrences(of: "\0", with: "")
                if !value.isEmpty { runs.append(MailTextRun(text: value, style: style, link: link)) }
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagNameNormal()
            let previous = kind
            let isBlock = blockTags.contains(tag)
            if isBlock {
                flush()
                if tag == "blockquote" { kind = .quote(depth: min(5, quote + 1)) }
                else if tag == "pre" { kind = .preformatted }
                else if tag == "li" { kind = .item(ordered: element.parent()?.tagNameNormal() == "ol", depth: 0, number: nil) }
                else if tag.count == 2 && tag.hasPrefix("h"), let level = Int(tag.dropFirst()) { kind = .heading(level: level) }
                else { kind = quote > 0 ? .quote(depth: min(5, quote)) : .paragraph }
            }
            var nextStyle = style
            if ["b", "strong"].contains(tag) { nextStyle.insert(.bold) }
            if ["i", "em"].contains(tag) { nextStyle.insert(.italic) }
            if tag == "u" { nextStyle.insert(.underline) }
            if tag == "strike" { nextStyle.insert(.strikethrough) }
            if tag == "code" { nextStyle.insert(.code) }
            var nextLink = link
            if tag == "a" {
                let href = try element.attr("href")
                let url = URL(string: href)
                if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                   !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { nextLink = url }
                else { nextLink = nil }
            }
            if tag == "br" { runs.append(MailTextRun(text: "\n", style: style, link: link)) }
            if ["td", "th"].contains(tag), !runs.isEmpty { runs.append(MailTextRun(text: "\t", link: nil)) }
            for child in element.getChildNodes() {
                try walk(child, style: nextStyle, link: nextLink, quote: quote + (tag == "blockquote" ? 1 : 0), pre: pre || tag == "pre")
            }
            if isBlock { flush(); kind = previous }
        }
        try walk(root, style: [], link: nil, quote: 0, pre: false)
        flush()
        return MailText(blocks: blocks)
    }
}

#endif
