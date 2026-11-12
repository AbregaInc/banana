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
    /// Use formatted HTML when the native grid cannot preserve a data table's structure.
    /// Optional so older cached bodies remain decodable until background preparation catches up.
    var prefersOriginal: Bool? = nil

    var body: MailBody {
        var notices: [MailBodyNotice] = shownAsText ? [.shownAsText] : []
        if prefersOriginal == true { notices.append(.designedLayout) }
        return .text(text, quoteStartsAt: quoteStartsAt, notices: notices)
    }

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
    static let version = 5
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumNodes = 50_000
    /// How deep the walk recurses; deeper content is read flat, in document order.
    static let maximumDepth = 48
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
            // Beyond what native text is made from: the plain part, else the words of as much of
            // the HTML as is taken. A message is never left without a body, so it is prepared once
            // and never asked for again (a failure here was retried on every pull, for ever).
            guard html.utf8.count <= maximumBytes else {
                if let shown = usablePlain(plain) { return shown }
                return try wordsOnly(SwiftSoup.parse(String(decoding: html.utf8.prefix(maximumBytes), as: UTF8.self)))
            }
            // Parsed as a document, not a body fragment: SwiftSoup builds a document's tree in one
            // bulk pass, but registers every node of a fragment with its document as it is inserted,
            // walking up its ancestors, which was half the parse. What moves to the head is title,
            // style, meta, link and base, never shown as text, and a noscript before any body
            // content, now not shown; a frameset document has no body and shows its plain part.
            let source = try SwiftSoup.parse(html)
            mark("parse")
            // Bound subsequent walks independently of the parser's input-size bound.
            // Depth is not a limit: below `maximumDepth` the walk reads a subtree's words flat
            // (`flatText`), so a newsletter of tables in tables, or a long chain of quoted replies,
            // still shows every word without recursing deeper. More pieces than are walked in time:
            // the plain part, else the document's words.
            if !withinBounds(source) { return try usablePlain(plain) ?? wordsOnly(source) }
            mark("bounds")
            // Native text reads only text nodes, the listed formatting tags and checked http/https/mailto
            // links, so it walks the parsed tree directly. Script and style content are data nodes and are
            // never read. The Original view prepares its own cleaned document (MailOriginalDocument).
            guard let body = source.body() else { return plainBody(plain ?? "", shownAsText: true) }
            let needs = DocNeeds(html)
            let (native, pictures) = try nativeText(body, needs: needs)
            mark("nativeText")
            if let measure {
                for (name, count) in pictures.named { measure("pictures." + name, Double(count)) }
            }
            let formatted = needsFormattedLayout(body, needs: needs)
            mark("layoutDecision")
            return MailPreparedBody(version: version, text: native, shownAsText: true,
                                    quoteStartsAt: MailPreparedBody.quoteStart(of: native.blocks),
                                    prefersOriginal: formatted)
        }
        return plainBody(clipped(plain ?? ""), shownAsText: false)
    }

    /// Select layout only when simplifying would lose a table's relationships.
    /// Fonts, colors, wrapper tables, signatures and quoted history are not evidence.
    /// This uses the same visibility and table rules as native preparation.
    static func needsFormattedLayout(_ root: Element, needs: DocNeeds) -> Bool {
        var stack: [Element] = [root]
        while let element = stack.popLast() {
            let tag = element.tagNameNormal()
            let traits = look(of: element, tag: tag, needs: needs)
            if traits.contains(.hidden) || traits.contains(.quoteHeader) || traits.contains(.outlookReply) || tag == "blockquote" { continue }
            if tag == "table", hasOwnDataSemantics(element) {
                // Native grids currently have no caption slot. Do not silently drop one.
                if elements(element).contains(where: { $0.tagNameNormal() == "caption" }) || tableShape(element, needs: needs) == nil { return true }
            }
            stack.append(contentsOf: elements(element))
        }
        return false
    }

    private static func hasOwnDataSemantics(_ table: Element) -> Bool {
        guard (try? table.attr("role")) != "presentation" else { return false }
        for child in elements(table) {
            let tag = child.tagNameNormal()
            if tag == "caption" { return true }
            let rows: [Element]
            switch tag {
            case "tr": rows = [child]
            case "thead", "tbody", "tfoot": rows = elements(child).filter { $0.tagNameNormal() == "tr" }
            default: continue
            }
            for row in rows {
                for cell in elements(row) {
                    let tag = cell.tagNameNormal()
                    if tag == "th" { return true }
                    if tag == "td", let span = try? cell.attr("rowspan"), (Int(span) ?? 1) > 1 { return true }
                }
            }
        }
        return false
    }

    /// Whether native text can be made from the tree in time: at most `maximumNodes` pieces. Depth is
    /// not counted; the walk reads what lies below `maximumDepth` flat.
    static func withinBounds(_ root: Node) -> Bool {
        var stack: [Node] = [root], nodes = 0
        while let node = stack.popLast() {
            nodes += 1
            guard nodes <= maximumNodes else { return false }
            stack.append(contentsOf: node.getChildNodes())
        }
        return true
    }

    /// A plain part worth showing instead of HTML that cannot be made native.
    private static func usablePlain(_ plain: String?) -> MailPreparedBody? {
        guard let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return plainBody(clipped(plain), shownAsText: true)
    }

    /// The document's words, in order, without its structure. The walk is iterative, so no
    /// nesting depth can exhaust the stack.
    private static func wordsOnly(_ document: Document) throws -> MailPreparedBody {
        plainBody(clipped(try (document.body() ?? document).text()), shownAsText: true)
    }

    /// At most `maximumBytes` of text, cut at a character boundary.
    private static func clipped(_ value: String) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: maximumBytes)
        while end.samePosition(in: value.unicodeScalars) == nil { end = value.utf8.index(before: end) }
        return String(value.unicodeScalars[..<end])
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
        static let k_colspan = Array("colspan".utf8)
        static let k_rowspan = Array("rowspan".utf8)
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
        var style = false, hidden = false, quote = false, outlook = false, preview = false, span = false

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
                    case UInt8(ascii: "c"): if match(i, "colspan") { span = true }
                    case UInt8(ascii: "r"): if match(i, "rowspan") { span = true }
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
        // A small icon (social buttons, bullets, check marks) is decoration, also when only one side is given.
        if let side = width ?? height, let other = height ?? width, side <= 32, other <= 32 { counts.decorative += 1; return nil }
        if case .cid = source { counts.cid += 1 }
        var alt = collapse((try? element.attr("alt")) ?? "").trimmingCharacters(in: .whitespaces)
        // "Shop, opens a new tab": what a screen reader is told about the link, not about the picture.
        for hint in [", opens a new tab", ", opens in a new tab", ", opens in a new window", " (opens in a new window)", " (opens in a new tab)", " - opens in a new window"] {
            if let range = alt.range(of: hint, options: [.caseInsensitive, .backwards]) { alt.removeSubrange(range) }
        }
        return MailPicture(source: source, width: width, height: height, alt: String(alt.prefix(200)), link: MailBodyHTML.safeLink(link))
    }


    // MARK: Tables

    struct TableCell { var element: Element; var header: Bool; var span: Int }
    static let maximumTableRows = 40
    static let maximumTableColumns = 8
    /// What a cell of a data table never holds: these lay a page out.
    private static let layoutInCell: Set<String> = ["table", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "hr"]
    private static let longestCell = 300

    private static func elements(_ node: Node) -> [Element] { node.getChildNodes().compactMap { $0 as? Element } }

    /// The rows and cells of a table that holds data: rows of the same width (two to eight columns),
    /// every cell short words with no layout inside, at least half the cells filled, and two rows
    /// with two filled cells. Anything else lays a page out (a single row is a row of links or a footer).
    static func tableShape(_ table: Element, needs: DocNeeds) -> (rows: [[TableCell]], columns: Int)? {
        var trs: [Element] = []
        for child in elements(table) {
            switch child.tagNameNormal() {
            case "tr": trs.append(child)
            case "thead", "tbody", "tfoot": trs.append(contentsOf: elements(child).filter { $0.tagNameNormal() == "tr" })
            default: break
            }
            guard trs.count <= maximumTableRows else { return nil }
        }
        guard !trs.isEmpty else { return nil }
        // First what costs nothing (tags and words), so a table that lays a page out is left before
        // any attribute is read: reading one through the parser is the slowest thing the walk does.
        var found: [(tr: Element, cells: [(cell: Element, header: Bool)])] = [], cells = 0, filled = 0, richRows = 0
        for tr in trs {
            var row: [(cell: Element, header: Bool)] = [], rowFilled = 0
            for cell in elements(tr) {
                let tag = cell.tagNameNormal()
                guard tag == "td" || tag == "th" else { continue }
                var length = 0, stack: [Node] = cell.getChildNodes()
                while let node = stack.popLast() {
                    if let text = node as? TextNode {
                        for scalar in text.getWholeText().unicodeScalars where !isSpace(scalar.value) && !isInvisible(scalar.value) { length += 1 }
                        guard length <= longestCell else { return nil }
                    } else if let element = node as? Element {
                        guard !layoutInCell.contains(element.tagNameNormal()) else { return nil }
                        stack.append(contentsOf: element.getChildNodes())
                    }
                }
                cells += 1
                if length > 0 { filled += 1; rowFilled += 1 }
                row.append((cell, tag == "th"))
            }
            if row.isEmpty { continue }
            if rowFilled >= 2 { richRows += 1 }
            found.append((tr, row))
        }
        guard richRows >= 2, filled * 2 >= cells else { return nil }
        // Then hidden rows and cells, and spans.
        var rows: [[TableCell]] = []
        for (tr, row) in found where !look(of: tr, tag: "tr", needs: needs).contains(.hidden) {
            var kept: [TableCell] = []
            for item in row where !look(of: item.cell, tag: item.header ? "th" : "td", needs: needs).contains(.hidden) {
                func number(_ key: [UInt8]) -> Int? {
                    guard needs.span else { return nil }
                    return (try? item.cell.attr(key)).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                }
                if let rowspan = number(Bytes.k_rowspan), rowspan > 1 { return nil }
                let span = min(max(number(Bytes.k_colspan) ?? 1, 1), maximumTableColumns)
                kept.append(TableCell(element: item.cell, header: item.header, span: span))
            }
            if !kept.isEmpty { rows.append(kept) }
        }
        let widths = rows.map { $0.reduce(0) { $0 + $1.span } }
        guard let columns = widths.max(), columns >= 2, columns <= maximumTableColumns,
              widths.filter({ $0 == columns }).count * 3 >= rows.count * 2,
              rows.count >= 2 else { return nil }
        return (rows, columns)
    }

    // MARK: Lists written as text

    /// "1." "2)" "(3)" number a list; "a." "b)", "•", "-" and the like mark one.
    static func listMarker(_ text: String) -> (number: Int?, length: Int)? {
        let scalars = Array(text.unicodeScalars.prefix(6))
        guard let first = scalars.first else { return nil }
        if ["\u{2022}", "\u{00B7}", "\u{25AA}", "\u{25E6}", "\u{2023}", "\u{2013}", "-", "*", "\u{25CF}", "\u{25A0}"].contains(first) {
            return (nil, 1)
        }
        var i = 0
        if first == "(" { i = 1 }
        var digits = ""
        while i < scalars.count, scalars[i].properties.numericType == .decimal, digits.count < 2 { digits.unicodeScalars.append(scalars[i]); i += 1 }
        var letter = false
        if digits.isEmpty, i < scalars.count, CharacterSet.lowercaseLetters.contains(scalars[i]), scalars[i].isASCII { letter = true; i += 1 }
        guard !digits.isEmpty || letter, i < scalars.count, scalars[i] == "." || scalars[i] == ")" else { return nil }
        if first == "(", scalars[i] != ")" { return nil }
        return (digits.isEmpty ? nil : Int(digits), i + 1)
    }

    private static func plainText(_ runs: [MailTextRun]) -> String { runs.map(\.text).joined() }

    /// "b. Pears": a marker, a space and words.
    static func startsWithMarker(_ text: String) -> Bool {
        guard let marker = listMarker(text) else { return false }
        return text.unicodeScalars.dropFirst(marker.length).first == " "
    }

    /// The runs without their first `count` characters (a list marker) and the space after it.
    private static func dropping(_ count: Int, from runs: [MailTextRun]) -> [MailTextRun] {
        var left = count
        var out: [MailTextRun] = []
        for var run in runs {
            if left > 0 {
                let scalars = run.text.unicodeScalars
                let take = min(left, scalars.count)
                run.text = String(String.UnicodeScalarView(scalars.dropFirst(take)))
                left -= take
                if left == 0 { run.text = String(run.text.drop(while: { $0 == " " })) }
            }
            if !run.text.isEmpty { out.append(run) }
        }
        return out
    }

    /// The lines of a block, split where it breaks.
    private static func lines(_ runs: [MailTextRun]) -> [[MailTextRun]] {
        var out: [[MailTextRun]] = [[]]
        for run in runs { if run.text == "\n" { out.append([]) } else { out[out.count - 1].append(run) } }
        return out.filter { !$0.isEmpty }
    }

    /// A line that starts with a marker and a space, as an item; nil otherwise.
    private static func item(_ runs: [MailTextRun]) -> MailTextBlock? {
        let text = plainText(runs)
        guard let marker = listMarker(text) else { return nil }
        let rest = text.unicodeScalars.dropFirst(marker.length)
        guard rest.first == " ", rest.contains(where: { !CharacterSet.whitespaces.contains($0) }) else { return nil }
        return MailTextBlock(kind: .item(ordered: marker.number != nil, depth: 0, number: marker.number), runs: dropping(marker.length, from: runs))
    }

    /// Lists a sender wrote as text become lists: a marker on its own line followed by its words ("1."
    /// then "Deposit $5,000…"), two or more lines that each start with a marker, and short lines that
    /// follow a sentence ending in a colon ("…for the following reasons:" then one reason a line).
    static func listsFromLines(_ blocks: [MailTextBlock]) -> [MailTextBlock] {
        var out: [MailTextBlock] = []
        out.reserveCapacity(blocks.count)
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            guard case .paragraph = block.kind else { out.append(block); i += 1; continue }
            let text = plainText(block.runs).trimmingCharacters(in: .whitespaces)
            // A marker alone, its words in the next paragraph.
            if let marker = listMarker(text), marker.length == text.unicodeScalars.count, i + 1 < blocks.count,
               case .paragraph = blocks[i + 1].kind, !plainText(blocks[i + 1].runs).isEmpty {
                out.append(MailTextBlock(kind: .item(ordered: marker.number != nil, depth: 0, number: marker.number), runs: blocks[i + 1].runs))
                i += 2
                continue
            }
            // Lines that each start with a marker, in one paragraph or in several.
            let split = lines(block.runs)
            if split.count >= 2, case let items = split.compactMap(item), items.count == split.count {
                out.append(contentsOf: items); i += 1; continue
            }
            if split.count == 1, let first = item(block.runs), i + 1 < blocks.count, case .paragraph = blocks[i + 1].kind,
               let second = item(blocks[i + 1].runs) {
                out.append(first); out.append(second)
                i += 2
                while i < blocks.count, case .paragraph = blocks[i].kind, let next = item(blocks[i].runs) { out.append(next); i += 1 }
                continue
            }
            out.append(block)
            i += 1
            // A lead-in ending in a colon, then short lines that are not sentences: one item each.
            guard text.hasSuffix(":"), text.count >= 12 else { continue }
            var j = i
            func isShortLine(_ b: MailTextBlock) -> Bool {
                guard case .paragraph = b.kind, !b.runs.contains(where: { $0.text == "\n" }) else { return false }
                let line = plainText(b.runs).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line.count <= 120, let last = line.last else { return false }
                return !".!?:".contains(last)
            }
            while j < blocks.count, isShortLine(blocks[j]) { j += 1 }
            guard j - i >= 2 else { continue }
            for k in i..<j { out.append(MailTextBlock(kind: .item(ordered: false, depth: 0, number: nil), runs: blocks[k].runs)) }
            i = j
        }
        return out
    }

    // MARK: Pictures beside their own link

    /// A linked picture next to a link to the same page, or to a link whose words its description names
    /// (a profile photo above the name, a logo by the shop's name), says nothing the words don't: it keeps its link but no description, so a picture
    /// that cannot be shown leaves no second label.
    static func picturesWithoutRepeatedLinks(_ blocks: [MailTextBlock]) -> [MailTextBlock] {
        var out = blocks
        for index in out.indices {
            guard case .picture(var picture) = out[index].kind, let link = picture.link, !picture.alt.isEmpty else { continue }
            let neighbours = [index - 1, index + 1].filter { out.indices.contains($0) }
            let alt = picture.alt.lowercased()
            func same(_ other: URL) -> Bool {
                other == link || (other.host != nil && other.host == link.host && other.path.count > 1 && other.path == link.path)
            }
            func named(_ run: MailTextRun) -> Bool {
                let words = run.text.trimmingCharacters(in: .whitespaces).lowercased()
                return words.count >= 3 && alt.contains(words)
            }
            guard neighbours.contains(where: { out[$0].runs.contains { run in run.link.map(same) == true || (run.link != nil && named(run)) } }) else { continue }
            picture.alt = ""
            out[index].kind = .picture(picture)
        }
        return out
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
        // Inside a data table's cell: words only, no pictures and no blocks of its own.
        var inCell = false

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
            while let last = cleaned.last, last.text.allSatisfy(\.isWhitespace) { cleaned.removeLast() }
            if var last = cleaned.last, last.text.last?.isWhitespace == true { while last.text.last?.isWhitespace == true { last.text.removeLast() }; cleaned[cleaned.count - 1] = last }
            guard cleaned.contains(where: { !$0.text.isEmpty }) else { return }
            var k = kind
            if let item = pendingItem, case .paragraph = k { k = item }
            pendingItem = nil
            if outlookQuote, case .quote = k {} else if outlookQuote { k = .quote(depth: 1) }
            // A break before a word that goes on in lower case only wrapped the line to the sender's
            // column ("Bank with the Power<br>of Membership"): in this column the sentence flows on.
            if k != .preformatted {
                for i in cleaned.indices.dropLast() where cleaned[i].text == "\n" {
                    guard let next = cleaned[i + 1].text.first, next.isLowercase, !startsWithMarker(cleaned[i + 1].text) else { continue }
                    cleaned[i].text = i > 0 && cleaned[i - 1].text.hasSuffix(" ") ? "" : " "
                }
                cleaned.removeAll { $0.text.isEmpty }
            }
            blocks.append(MailTextBlock(kind: k, runs: cleaned))
        }

        func append(_ text: String, style: MailTextStyle, link: URL?) {
            guard !text.isEmpty else { return }
            // A link around nothing but space (a padded table cell) is no link: there is nothing to tap.
            let link = link != nil && text.allSatisfy({ $0 == " " || $0 == "\n" }) ? nil : link
            if text != " " && text != "\n" { hasVisible = hasVisible || text.contains(where: { $0 != " " }) }
            if let last = runs.last, last.style == style, last.link == link, text != "\n", last.text != "\n" {
                runs[runs.count - 1].text += text
            } else {
                runs.append(MailTextRun(text: text, style: style, link: link))
            }
        }

        func shortened(_ text: String) -> String { displayAddress(text) }

        func walk(_ node: Node, style: MailTextStyle, link: URL?, quote: Int, pre: Bool, depth: Int) throws {
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
            if depth >= maximumDepth { flatText(element, style: style, link: link); return }
            let tag = element.tagNameNormal()
            let traits = look(of: element, tag: tag, needs: needs)
            if traits.contains(.hidden) { return }
            if tag == "table", quote == 0, !outlookQuote, !inCell, !pre, let found = try table(element, depth: depth) {
                flush()
                blocks.append(contentsOf: found)
                return
            }
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
                if inCell { counts.decorative += 1; return }
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
            // One gap between cells however many empty cells lie between them (a calendar's blank days).
            if tag == "td" || tag == "th", hasVisible, runs.last?.text.hasSuffix(cellSeparator) != true { append(cellSeparator, style: [], link: nil) }
            for child in element.getChildNodes() {
                try walk(child, style: nextStyle, link: nextLink, quote: quote, pre: pre || tag == "pre", depth: depth + 1)
            }
            if isBlock {
                flush()
                kind = previous
                if tag == "li" { pendingItem = nil }
                if tag == "ul" || tag == "ol" { _ = lists.popLast() }
            }
        }
        /// A subtree below `maximumDepth`, read without recursion: its words in document order, a block
        /// element ending a line, a break a line break, its links kept; hidden parts and pictures skipped.
        func flatText(_ start: Element, style: MailTextStyle, link: URL?) {
            enum Step { case enter(Node, URL?), leave }
            var steps: [Step] = [.enter(start, link)]
            while let step = steps.popLast() {
                guard case .enter(let node, let link) = step else { flush(); continue }
                if let text = node as? TextNode {
                    let value = collapse(text.getWholeText())
                    if !value.isEmpty { append(value, style: style, link: link) }
                    continue
                }
                guard let element = node as? Element else { continue }
                let tag = element.tagNameNormal()
                if look(of: element, tag: tag, needs: needs).contains(.hidden) || tag == "img" { continue }
                if tag == "br" { if hasVisible { append("\n", style: style, link: nil) }; continue }
                var inner = link
                if tag == "a" {
                    let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = URL(string: href)
                    if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                       !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { inner = url } else { inner = nil }
                }
                let block = blockTags.contains(tag) || tag == "td" || tag == "th"
                if block { flush(); steps.append(.leave) }
                for child in element.getChildNodes().reversed() { steps.append(.enter(child, inner)) }
            }
        }

        /// The runs a cell's content makes, its lines joined by line breaks.
        func cellRuns(_ cell: Element, depth: Int) throws -> [MailTextRun] {
            let saved = (blocks, runs, hasVisible, kind, pendingItem, lists)
            blocks = []; runs = []; hasVisible = false; kind = .paragraph; pendingItem = nil; lists = []
            inCell = true
            defer { (blocks, runs, hasVisible, kind, pendingItem, lists) = saved; inCell = false }
            for child in cell.getChildNodes() {
                try walk(child, style: [], link: nil, quote: 0, pre: false, depth: depth + 1)
            }
            flush()
            var out: [MailTextRun] = []
            for block in blocks {
                if !out.isEmpty { out.append(MailTextRun(text: "\n", link: nil)) }
                out.append(contentsOf: block.runs)
            }
            return out
        }

        /// A table of data as a grid (or, when its first column only numbers or bullets the rows, as a
        /// list); nil for a table that lays a page out, which is read as text as before.
        func table(_ element: Element, depth: Int) throws -> [MailTextBlock]? {
            guard let shape = tableShape(element, needs: needs) else { return nil }
            var grid: [[MailTable.Cell]] = []
            for row in shape.rows {
                var cells: [MailTable.Cell] = []
                for cell in row {
                    let runs = try cellRuns(cell.element, depth: depth)
                    cells.append(MailTable.Cell(runs: runs, header: cell.header))
                    for _ in 1..<max(1, cell.span) { cells.append(MailTable.Cell(runs: [], header: cell.header)) }
                }
                while cells.count < shape.columns { cells.append(MailTable.Cell(runs: [])) }
                grid.append(Array(cells.prefix(shape.columns)))
            }
            // What each cell says, worked out once.
            let words = grid.map { row in row.map { MailHTMLPreparer.plainText($0.runs).trimmingCharacters(in: .whitespaces) } }
            // Empty columns (spacer cells) and empty rows are not part of the table.
            let used = (0..<shape.columns).filter { column in words.contains { !$0[column].isEmpty } }
            let kept = grid.indices.filter { row in used.contains { !words[row][$0].isEmpty } }
            guard used.count >= 2, !kept.isEmpty else { return nil }
            grid = kept.map { row in used.map { grid[row][$0] } }
            let shown = kept.map { row in used.map { words[row][$0] } }
            // "1." | "Deposit $5,000…": a list laid out in a table.
            if used.count == 2, grid.count >= 2, shown.allSatisfy({ listMarker($0[0])?.length == $0[0].unicodeScalars.count && !$0[1].isEmpty }) {
                return zip(grid, shown).map { row, text in
                    let number = listMarker(text[0])?.number
                    return MailTextBlock(kind: .item(ordered: number != nil, depth: 0, number: number), runs: row[1].runs)
                }
            }
            var flat: [MailTextRun] = []
            for (index, row) in grid.enumerated() {
                if index > 0 { flat.append(MailTextRun(text: "\n", link: nil)) }
                for (column, cell) in row.enumerated() {
                    if column > 0 { flat.append(MailTextRun(text: cellSeparator, link: nil)) }
                    flat.append(contentsOf: cell.runs.map { var run = $0; if run.text == "\n" { run.text = " " }; return run })
                }
            }
            return [MailTextBlock(kind: .table(MailTable(rows: grid)), runs: flat)]
        }

        try walk(root, style: [], link: nil, quote: 0, pre: false, depth: 0)
        flush()
        let joined = attributionsJoinedToTheirQuotes(blocks)
        let listed = listsFromLines(joined)
        let marked = markingFinePrint(picturesWithoutRepeatedLinks(listed), counts: &counts)
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
