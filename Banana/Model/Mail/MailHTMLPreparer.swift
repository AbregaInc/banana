#if !BANANA_PUBLIC
import Foundation
import SwiftSoup

struct MailPreparedBody: Codable, Equatable, Sendable {
    var version: Int
    var text: MailText
    var shownAsText: Bool
    /// Index of the first block of the quoted tail: every block from here on is quoted. Nil when the
    /// message does not end in a quote. Made with the text, so opening a message costs nothing.
    var quoteStartsAt: Int? = nil

    var body: MailBody { .text(text, quoteStartsAt: quoteStartsAt, notices: shownAsText ? [.shownAsText] : []) }

    static func quoteStart(of blocks: [MailTextBlock]) -> Int? {
        var start: Int?
        for (index, block) in blocks.enumerated().reversed() {
            guard case .quote = block.kind else { break }
            start = index
        }
        // A message that is only a quote (a forward) has nothing to fold it under.
        return start == 0 ? nil : start
    }
}

/// Runs on the preparation worker, before opening. Uses the pinned library's parser.
enum MailHTMLPreparer {
    static let version = 3
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
            // Parsed as a document, not a body fragment: SwiftSoup builds a document's tree in one
            // bulk pass, but registers every node of a fragment with its document as it is inserted,
            // walking up its ancestors, which was half the parse. What moves to the head is title,
            // style, meta, link and base, never shown as text, and a noscript before any body
            // content, now not shown; a frameset document has no body and shows its plain part.
            let source = try SwiftSoup.parse(html)
            mark("parse")
            // Bound subsequent walks independently of the parser's input-size bound.
            var stack: [(Node, Int)] = [(source, 0)], nodes = 0
            while let (node, depth) = stack.popLast() {
                nodes += 1
                guard nodes <= 50_000, depth <= 64 else { throw Failure.tooComplex }
                for child in node.getChildNodes() { stack.append((child, depth + 1)) }
            }
            mark("bounds")
            // Native text reads only text nodes, the listed formatting tags and checked http/https/mailto
            // links, so it walks the parsed tree directly. Script and style content are data nodes and are
            // never read. The Original view prepares its own cleaned document (MailOriginalDocument).
            guard let body = source.body() else { return plainBody(plain ?? "", shownAsText: true) }
            let (native, pictures) = try nativeText(body, needs: DocNeeds(html))
            mark("nativeText")
            if let measure {
                for (name, count) in pictures.named { measure("pictures." + name, Double(count)) }
            }
            return MailPreparedBody(version: version, text: native, shownAsText: true, quoteStartsAt: MailPreparedBody.quoteStart(of: native.blocks))
        }
        guard (plain?.utf8.count ?? 0) <= maximumBytes else { throw Failure.tooLarge }
        return plainBody(plain ?? "", shownAsText: false)
    }

    private static func plainBody(_ value: String, shownAsText: Bool) -> MailPreparedBody {
        MailPreparedBody(version: version, text: MailText(blocks: [MailTextBlock(kind: .preformatted,
            runs: [MailTextRun(text: value.replacingOccurrences(of: "\0", with: ""), link: nil)])]),
            shownAsText: shownAsText)
    }

    // MARK: Native text

    /// Characters that take no room on screen: zero-width and joiner characters, soft hyphens, the
    /// combining grapheme joiner and byte-order marks. Newsletters pad their preview line with them.
    @inline(__always) private static func isInvisible(_ v: UInt32) -> Bool {
        switch v {
        case 0x00AD, 0x034F, 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF: return true
        default: return false
        }
    }

    @inline(__always) private static func isSpace(_ v: UInt32) -> Bool {
        switch v {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// Text as a browser lays it out: invisible characters gone, every run of white space one space.
    static func collapse(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if v == 0 || isInvisible(v) { continue }
            if isSpace(v) {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(scalar)
                lastSpace = false
            }
        }
        return String(out)
    }

    private static func stripInvisible(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar.value != 0 && !isInvisible(scalar.value) { out.append(scalar) }
        return String(out)
    }

    private enum Bytes {
        static let k_0 = Array("0".utf8)
        static let k_0_0 = Array("0.0".utf8)
        static let k_block = Array("block".utf8)
        static let k_class = Array("class".utf8)
        static let k_display = Array("display".utf8)
        static let k_divRplyFwdMsg = Array("divRplyFwdMsg".utf8)
        static let k_flex = Array("flex".utf8)
        static let k_float = Array("float".utf8)
        static let k_font_size = Array("font-size".utf8)
        static let k_grid = Array("grid".utf8)
        static let k_hidden = Array("hidden".utf8)
        static let k_id = Array("id".utf8)
        static let k_inline_block = Array("inline-block".utf8)
        static let k_left = Array("left".utf8)
        static let k_mail_editor_reference_message_container = Array("mail-editor-reference-message-container".utf8)
        static let k_max_height = Array("max-height".utf8)
        static let k_none = Array("none".utf8)
        static let k_opacity = Array("opacity".utf8)
        static let k_overflow = Array("overflow".utf8)
        static let k_right = Array("right".utf8)
        static let k_style = Array("style".utf8)
        static let k_visibility = Array("visibility".utf8)
    }

    /// Which attributes the message could possibly use that matter here, found in one pass over its bytes. Reading an
    /// attribute through the parser is the slowest thing the walk does, so a message that cannot use one never pays for it.
    struct DocNeeds {
        var style = false, hidden = false, quote = false, outlook = false, preview = false

        init(_ html: String) {
            var copy = html
            copy.withUTF8 { b in
                let n = b.count
                func match(_ i: Int, _ word: StaticString) -> Bool {
                    let len = word.utf8CodeUnitCount
                    guard i + len <= n else { return false }
                    return word.withUTF8Buffer { w in
                        for j in 0..<len { var c = b[i + j]; if c >= 65 && c <= 90 { c += 32 }; if c != w[j] { return false } }
                        return true
                    }
                }
                var i = 0
                while i < n {
                    var c = b[i]; if c >= 65 && c <= 90 { c += 32 }
                    switch c {
                    case UInt8(ascii: "d"):
                        if match(i, "display") { style = true } else if match(i, "divrplyfwdmsg") { outlook = true }
                    case UInt8(ascii: "f"):
                        if match(i, "float") { style = true }
                        else if match(i, "font-size") {
                            var j = i + 9
                            while j < n, b[j] == 32 { j += 1 }
                            if j < n, b[j] == 58 { j += 1; while j < n, b[j] == 32 { j += 1 }; if j < n, b[j] == 48 { style = true } }
                        }
                    case UInt8(ascii: "v"): if match(i, "visibility") { style = true }
                    case UInt8(ascii: "o"): if match(i, "opacity") { style = true }
                    case UInt8(ascii: "m"):
                        if match(i, "max-height") { style = true }
                        else if match(i, "mcnpreviewtext") { preview = true }
                        else if match(i, "moz-cite-prefix") { quote = true }
                        else if match(i, "mail-editor-reference-message-container") { outlook = true }
                    case UInt8(ascii: "h"):
                        // The attribute (` hidden>` or ` hidden=`), not the CSS value (`overflow: hidden;`).
                        if match(i, "hidden"), i > 0, b[i - 1] == 32, i + 6 < n, b[i + 6] == 62 || b[i + 6] == 61 || b[i + 6] == 32 || b[i + 6] == 47 { hidden = true }
                    case UInt8(ascii: "g"): if match(i, "gmail_attr") { quote = true }
                    case UInt8(ascii: "y"): if match(i, "yahoo_quoted") { quote = true }
                    default: break
                    }
                    i += 1
                }
            }
        }
    }

    /// What an element's own attributes say about layout, read in one pass over the bytes (no lower-cased copy
    /// of the style, no Character walks: preparation runs on every message that arrives).
    struct Look: OptionSet {
        let rawValue: Int
        static let hidden = Look(rawValue: 1)
        static let zeroFont = Look(rawValue: 2)
        static let sideBySide = Look(rawValue: 4)
        static let block = Look(rawValue: 8)
        static let quoteHeader = Look(rawValue: 16)
        static let outlookReply = Look(rawValue: 32)
    }

    private static func contains(_ hay: [UInt8], _ needle: StaticString) -> Bool {
        let n = needle.utf8CodeUnitCount
        guard hay.count >= n else { return false }
        return needle.withUTF8Buffer { pattern in
            var i = 0
            while i + n <= hay.count {
                var j = 0
                while j < n {
                    var c = hay[i + j]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != pattern[j] { break }
                    j += 1
                }
                if j == n { return true }
                i += 1
            }
            return false
        }
    }

    private static let looksAt: Set<String> = ["img", "div", "span", "p", "td", "th", "tr", "table", "li", "ul", "ol", "section", "center", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6", "a", "article", "header", "footer", "main", "figure"]

    private static func look(of element: Element, tag: String, needs: DocNeeds) -> Look {
        var look: Look = []
        switch tag {
        case "head", "title", "template", "meta", "link", "base", "object", "embed", "canvas", "audio", "video": return .hidden
        default: break
        }
        // Each attribute read costs a weak-reference load inside the parser: look only where layout or hiding is decided.
        guard looksAt.contains(tag) else { return look }
        // `attr` on an element that has no attributes allocates nothing; `getAttributes()` would.
        if needs.style, let style = try? element.attr(Bytes.k_style), !style.isEmpty { look.formUnion(styleLook(style)) }
        if needs.preview || needs.quote, let value = try? element.attr(Bytes.k_class), !value.isEmpty {
            if contains(value, "mcnpreviewtext") { look.insert(.hidden) }
            if contains(value, "gmail_attr") || contains(value, "moz-cite-prefix") || contains(value, "yahoo_quoted") { look.insert(.quoteHeader) }
        }
        if needs.hidden, element.hasAttr(Bytes.k_hidden) { look.insert(.hidden) }
        if needs.outlook, tag == "div", let value = try? element.attr(Bytes.k_id), !value.isEmpty,
           value == Bytes.k_divRplyFwdMsg || value == Bytes.k_mail_editor_reference_message_container { look.insert(.outlookReply) }
        // Zero font size hides a leaf (preview padding). On a container it is a layout trick: its cells set their own size.
        if look.contains(.zeroFont) {
            if !element.getChildNodes().contains(where: { $0 is Element }) { look.insert(.hidden) }
        }
        return look
    }

    /// `display`, `visibility`, `opacity`, `max-height`/`overflow`, `font-size` and `float`: what decides whether text is
    /// seen and whether boxes stand beside each other. Names and values are compared lower-cased without white space.
    private static func styleLook(_ style: [UInt8]) -> Look {
        var look: Look = []
        var name: [UInt8] = [], value: [UInt8] = []
        var inValue = false
        var maxHeightZero = false, overflowHidden = false
        func finish() {
            defer { name.removeAll(keepingCapacity: true); value.removeAll(keepingCapacity: true); inValue = false }
            guard inValue else { return }
            switch name.count {
            case 7 where name == Bytes.k_display:
                if value == Bytes.k_none { look.insert(.hidden) }
                else if value == Bytes.k_block || value == Bytes.k_flex || value == Bytes.k_grid { look.insert(.block) }
                else if value == Bytes.k_inline_block { look.insert(.sideBySide) }
            case 10 where name == Bytes.k_visibility:
                if value == Bytes.k_hidden { look.insert(.hidden) }
            case 7 where name == Bytes.k_opacity:
                if value == Bytes.k_0 || value == Bytes.k_0_0 { look.insert(.hidden) }
            case 10 where name == Bytes.k_max_height:
                if value.first == 48, value.dropFirst().allSatisfy({ !($0 >= 49 && $0 <= 57) && $0 != 46 }) { maxHeightZero = true }
            case 8 where name == Bytes.k_overflow:
                if value == Bytes.k_hidden { overflowHidden = true }
            case 9 where name == Bytes.k_font_size:
                if value.first == 48, value.dropFirst().allSatisfy({ !($0 >= 49 && $0 <= 57) && $0 != 46 }) { look.insert(.zeroFont) }
            case 5 where name == Bytes.k_float:
                if value == Bytes.k_left || value == Bytes.k_right { look.insert(.sideBySide) }
            default: break
            }
        }
        for byte in style {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case 0x3A: if inValue { value.append(byte) } else { inValue = true }
            case 0x3B: finish()
            default:
                let c = (byte >= 65 && byte <= 90) ? byte + 32 : byte
                if inValue { value.append(c) } else { name.append(c) }
            }
        }
        finish()
        if maxHeightZero && overflowHidden { look.insert(.hidden) }
        return look
    }

    private static let blockTags: Set<String> = ["p", "div", "blockquote", "li", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "tr",
        "table", "ul", "ol", "section", "article", "header", "footer", "main", "aside", "nav", "address", "figure", "figcaption", "dl", "dt", "dd", "form", "center", "hr"]
    private static let cellSeparator = "\u{2003}\u{2003}"

    /// A link shown as its own address: where it goes, without scheme, tracking query or length. A search
    /// engine's redirect shows the page it redirects to.
    static func displayAddress(_ text: String) -> String {
        guard text.count > 40, let url = URL(string: text), let host = url.host else { return text }
        var target = url
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           host.hasSuffix("google.com"), url.path == "/url",
           let value = items.first(where: { $0.name == "q" || $0.name == "url" })?.value, let inner = URL(string: value), inner.host != nil { target = inner }
        var shown = (target.host ?? host).replacingOccurrences(of: "www.", with: "", options: .anchored)
        let path = target.path
        if path.count > 1 { shown += path }
        if shown.count > 36 { shown = String(shown.prefix(35)) + "\u{2026}" }
        return shown
    }


    // MARK: Pictures

    static let maximumPictures = 40

    struct PictureCounts {
        var kept = 0, tracker = 0, decorative = 0, quoted = 0, fineprint = 0, capped = 0, unsupported = 0, cid = 0
        var named: [(String, Int)] { [("kept", kept), ("tracker", tracker), ("decorative", decorative), ("quoted", quoted),
                                      ("fineprint", fineprint), ("capped", capped), ("unsupported", unsupported), ("cid", cid)] }
    }

    /// Path pieces that name a tracking pixel when the picture says nothing about its size.
    private static let trackerPaths: [StaticString] = ["/open", "/o/", "/e/o", "pixel", "beacon", "/track", "/imp/", "impression", "spacer", "blank.gif", "clear.gif", "transparent.gif"]

    /// A number of CSS pixels from an attribute or a style value: `120`, `120px`; not `100%` or `auto`.
    private static func pixels(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = text.hasSuffix("px") ? String(text.dropLast(2)) : text
        guard let number = Double(digits), number >= 0, number < 10_000 else { return nil }
        return Int(number.rounded())
    }

    private static func declaredSize(_ style: [UInt8]) -> (width: Int?, height: Int?) {
        var width: Int?, height: Int?
        for declaration in String(decoding: style, as: UTF8.self).split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "width" { width = pixels(String(parts[1])) } else if name == "height" { height = pixels(String(parts[1])) }
        }
        return (width, height)
    }

    /// The picture an `img` stands for, or nil when it is a tracker, a spacer, an icon or something that cannot be shown.
    private static func picture(of element: Element, link: URL?, counts: inout PictureCounts) -> MailPicture? {
        let raw = ((try? element.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { counts.unsupported += 1; return nil }
        var width = (try? element.attr("width")).flatMap(pixels)
        var height = (try? element.attr("height")).flatMap(pixels)
        if width == nil || height == nil, let style = try? element.attr(Bytes.k_style), !style.isEmpty {
            let declared = declaredSize(style)
            width = width ?? declared.width
            height = height ?? declared.height
        }
        // One to three pixels is a pixel or a spacer, whatever its address.
        if let width, width <= 3 { counts.tracker += 1; return nil }
        if let height, height <= 3 { counts.tracker += 1; return nil }
        let source: MailPicture.Source
        let lower = raw.lowercased()
        if lower.hasPrefix("cid:") {
            let id = String(raw.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !id.isEmpty else { counts.unsupported += 1; return nil }
            source = .cid(id)
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: raw), url.host != nil,
                  !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            if width == nil && height == nil {
                let bytes = Array(lower.utf8)
                for needle in trackerPaths where contains(bytes, needle) { counts.tracker += 1; return nil }
            }
            source = .remote(url)
        } else {
            counts.unsupported += 1
            return nil
        }
        // A small icon (social buttons, bullets, check marks) is decoration.
        if let width, let height, width <= 32, height <= 32 { counts.decorative += 1; return nil }
        if case .cid = source { counts.cid += 1 }
        let alt = collapse((try? element.attr("alt")) ?? "").trimmingCharacters(in: .whitespaces)
        return MailPicture(source: source, width: width, height: height, alt: String(alt.prefix(200)), link: MailBodyHTML.safeLink(link))
    }

    // MARK: Fine print

    private static let finePrintNeedles: [StaticString] = ["unsubscribe", "manage preferences", "manage your preferences", "email preferences", "update your preferences",
        "update preferences", "privacy policy", "all rights reserved", "\u{00A9}", "you are receiving", "you're receiving", "you received this", "you are subscribed",
        "you're subscribed", "opt out", "opt-out", "this email was sent", "this message was sent", "view in browser", "view this email", "terms of service"]

    private static func isFinePrint(_ block: MailTextBlock) -> Bool {
        var length = 0
        for run in block.runs { length += run.text.utf8.count }
        guard length <= 600 else { return false }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for run in block.runs { bytes.append(contentsOf: run.text.utf8) }
        for needle in finePrintNeedles where contains(bytes, needle) { return true }
        return false
    }

    /// From the first piece of boilerplate in the last part of a sender's message to its end. Replies people write
    /// have none of these words in their closing lines; a newsletter's footer starts with them.
    private static func markingFinePrint(_ blocks: [MailTextBlock], counts: inout PictureCounts) -> [MailTextBlock] {
        guard blocks.count >= 3 else { return blocks }
        let earliest = max(1, blocks.count / 2)
        var start: Int?
        for index in earliest..<blocks.count {
            if case .paragraph = blocks[index].kind, isFinePrint(blocks[index]) { start = index; break }
        }
        guard var first = start else { return blocks }
        // The line or two above it that only name the sender or give its address belong with it.
        while first > earliest, case .paragraph = blocks[first - 1].kind, blocks[first - 1].runs.reduce(0, { $0 + $1.text.utf8.count }) <= 80,
              blocks[first - 1].runs.allSatisfy({ $0.link == nil }) { first -= 1 }
        var out = blocks
        for index in first..<out.count {
            switch out[index].kind {
            case .paragraph, .heading: out[index].kind = .fineprint
            default: break
            }
        }
        // Pictures under the boilerplate are its social icons, badges and logos.
        let before = out.count
        out = Array(out[..<first]) + out[first...].filter { if case .picture = $0.kind { return false }; return true }
        counts.fineprint += before - out.count
        counts.kept -= before - out.count
        return out
    }

    private static func nativeText(_ root: Element, needs: DocNeeds) throws -> (MailText, PictureCounts) {
        var blocks: [MailTextBlock] = [], runs: [MailTextRun] = []
        var kind = MailTextBlock.Kind.paragraph
        var hasVisible = false
        var lists: [(ordered: Bool, count: Int)] = []
        var outlookQuote = false
        // A list item whose text sits in a div or p (Outlook, Apple Mail): the first block inside it is the item.
        var pendingItem: MailTextBlock.Kind?
        var counts = PictureCounts()

        func flush() {
            defer { runs.removeAll(keepingCapacity: true); hasVisible = false }
            guard hasVisible else { return }
            // Trim the block, and keep one space between runs, never two.
            var cleaned: [MailTextRun] = []
            cleaned.reserveCapacity(runs.count)
            var atStart = true
            for var run in runs {
                if run.text == "\n" {
                    while let last = cleaned.last, last.text == " " { cleaned.removeLast() }
                    if !atStart { cleaned.append(run) }
                    atStart = true
                    continue
                }
                if atStart { run.text = String(run.text.drop(while: { $0 == " " })) }
                else if run.text.hasPrefix(" "), let last = cleaned.last, last.text.hasSuffix(" ") || last.text.hasSuffix("\n") { run.text = String(run.text.dropFirst()) }
                if run.text.isEmpty { continue }
                atStart = false
                cleaned.append(run)
            }
            while let last = cleaned.last, last.text == "\n" || last.text.allSatisfy({ $0 == " " }) { cleaned.removeLast() }
            if var last = cleaned.last, last.text.hasSuffix(" ") { while last.text.hasSuffix(" ") { last.text.removeLast() }; cleaned[cleaned.count - 1] = last }
            guard cleaned.contains(where: { !$0.text.isEmpty }) else { return }
            var k = kind
            if let item = pendingItem, case .paragraph = k { k = item }
            pendingItem = nil
            if outlookQuote, case .quote = k {} else if outlookQuote { k = .quote(depth: 1) }
            blocks.append(MailTextBlock(kind: k, runs: cleaned))
        }

        func append(_ text: String, style: MailTextStyle, link: URL?) {
            guard !text.isEmpty else { return }
            if text != " " && text != "\n" { hasVisible = hasVisible || text.contains(where: { $0 != " " }) }
            if let last = runs.last, last.style == style, last.link == link, text != "\n", last.text != "\n" {
                runs[runs.count - 1].text += text
            } else {
                runs.append(MailTextRun(text: text, style: style, link: link))
            }
        }

        func shortened(_ text: String) -> String { displayAddress(text) }

        func walk(_ node: Node, style: MailTextStyle, link: URL?, quote: Int, pre: Bool) throws {
            if let text = node as? TextNode {
                if pre {
                    let value = stripInvisible(text.getWholeText())
                    if !value.isEmpty { append(value, style: style, link: link) }
                } else {
                    var value = collapse(text.getWholeText())
                    if link != nil, value.hasPrefix("http") || value.hasPrefix(" http") { value = shortened(value.trimmingCharacters(in: .whitespaces)) }
                    if !value.isEmpty { append(value, style: style, link: link) }
                }
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagNameNormal()
            let traits = look(of: element, tag: tag, needs: needs)
            if traits.contains(.hidden) { return }
            let previous = kind
            // Floated and inline-block boxes sit side by side (a label and its value): one line, a gap between.
            let sideBySide = traits.contains(.sideBySide)
            let isBlock = blockTags.contains(tag) || (traits.contains(.block) && !sideBySide)
            if sideBySide, hasVisible { append(cellSeparator, style: [], link: nil) }
            var quote = quote
            let isAttribution = traits.contains(.quoteHeader)
            if traits.contains(.outlookReply) { outlookQuote = true }
            if tag == "hr" { flush(); blocks.append(MailTextBlock(kind: .rule, runs: [])); return }
            if tag == "img" {
                guard let picture = picture(of: element, link: link, counts: &counts) else { return }
                if quote > 0 || outlookQuote { counts.quoted += 1; return }
                if case .picture(let last)? = blocks.last?.kind, last.source == picture.source { return }
                if counts.kept >= maximumPictures { counts.capped += 1; return }
                counts.kept += 1
                flush()
                blocks.append(MailTextBlock(kind: .picture(picture), runs: []))
                return
            }
            if isBlock {
                flush()
                if tag == "blockquote" { quote += 1 }
                else if isAttribution { quote = max(quote, 1) }
                if tag == "blockquote" || isAttribution { kind = .quote(depth: min(5, quote)) }
                else if tag == "pre" { kind = .preformatted }
                else if tag == "li" {
                    let top = lists.count - 1
                    if top >= 0 { lists[top].count += 1 }
                    kind = .item(ordered: top >= 0 && lists[top].ordered, depth: max(0, lists.count - 1), number: top >= 0 && lists[top].ordered ? lists[top].count : nil)
                    pendingItem = kind
                }
                else if tag.count == 2 && tag.hasPrefix("h"), let level = Int(tag.dropFirst()), level >= 1, level <= 6 { kind = .heading(level: level) }
                else if tag == "ul" || tag == "ol" {
                    var start = 0
                    if tag == "ol", let s = try? element.attr("start"), let n = Int(s) { start = n - 1 }
                    lists.append((tag == "ol", start))
                    kind = quote > 0 ? .quote(depth: min(5, quote)) : .paragraph
                }
                else { kind = quote > 0 ? .quote(depth: min(5, quote)) : .paragraph }
            } else if isAttribution { quote = max(quote, 1) }
            var nextStyle = style
            switch tag {
            case "b", "strong": nextStyle.insert(.bold)
            case "i", "em", "cite": nextStyle.insert(.italic)
            case "u", "ins": nextStyle.insert(.underline)
            case "strike", "s", "del": nextStyle.insert(.strikethrough)
            case "code", "tt", "kbd", "samp": nextStyle.insert(.code)
            case "th": nextStyle.insert(.bold)
            default: break
            }
            if tag == "h1" || tag == "h2" || tag == "h3" || tag == "h4" || tag == "h5" || tag == "h6" { nextStyle = style }
            var nextLink = link
            if tag == "a" {
                let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                let url = URL(string: href)
                if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                   !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { nextLink = url }
                else { nextLink = nil }
            }
            if tag == "br" {
                if let last = runs.last, last.text == "\n" { flush() } else if hasVisible { append("\n", style: style, link: nil) }
            }
            if tag == "td" || tag == "th", hasVisible { append(cellSeparator, style: [], link: nil) }
            for child in element.getChildNodes() {
                try walk(child, style: nextStyle, link: nextLink, quote: quote, pre: pre || tag == "pre")
            }
            if isBlock {
                flush()
                kind = previous
                if tag == "li" { pendingItem = nil }
                if tag == "ul" || tag == "ol" { _ = lists.popLast() }
            }
        }
        try walk(root, style: [], link: nil, quote: 0, pre: false)
        flush()
        let marked = markingFinePrint(attributionsJoinedToTheirQuotes(blocks), counts: &counts)
        return (MailText(blocks: marked), counts)
    }

    /// "On Tue, Nov 3, Ann wrote:" that a client wrote as a plain line above its quote belongs to the quote.
    private static func attributionsJoinedToTheirQuotes(_ blocks: [MailTextBlock]) -> [MailTextBlock] {
        var out = blocks
        var i = 0
        while i + 1 < out.count {
            if case .paragraph = out[i].kind, case .quote(let depth) = out[i + 1].kind, looksLikeAttribution(out[i]) {
                out[i].kind = .quote(depth: depth)
            }
            i += 1
        }
        return out
    }

    private static func looksLikeAttribution(_ block: MailTextBlock) -> Bool {
        let text = block.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard text.count < 300, text.count > 8 else { return false }
        for suffix in [" wrote:", " schrieb:", " a \u{00E9}crit :", " a \u{00E9}crit:", " escribi\u{00F3}:", " ha scritto:", " skrev:", " schreef:"] where text.hasSuffix(suffix) { return true }
        return text.hasPrefix("-------") || text.hasPrefix("From:") && text.contains("Sent:")
    }
}

#endif
