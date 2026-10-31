import Foundation

/// A JSON value as the data platform moves it (docs/design/DATA-PLATFORM.md §3): a record's fields
/// are a JSON object of these. Numbers keep whether they were whole, so an `Int` field comes back
/// an `Int`; `1` and `1.0` are the same value (as in JavaScript, where the service merges).
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Integers JavaScript holds exactly (|n| ≤ 2^53): the service parses every number as a double.
    static let exactIntegers: Double = 9_007_199_254_740_992
    static let exactIntegerMagnitude: UInt64 = 1 << 53

    /// A whole double JavaScript holds exactly is the same number as that integer.
    fileprivate var normalized: JSONValue {
        if case .double(let d) = self, d.rounded() == d, abs(d) <= Self.exactIntegers { return .int(Int64(d)) }
        return self
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs.normalized, rhs.normalized) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch normalized {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(1); hasher.combine(b)
        case .int(let i): hasher.combine(2); hasher.combine(i)
        case .double(let d): hasher.combine(3); hasher.combine(d)
        case .string(let s): hasher.combine(4); hasher.combine(s)
        case .array(let a): hasher.combine(5); hasher.combine(a)
        case .object(let o): hasher.combine(6); hasher.combine(o)
        }
    }

    var isNull: Bool { if case .null = self { true } else { false } }

    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }

    /// A blob reference `{"$blob": "<sha256>", "size": n, "ext": "jpg"}` (§3, "Blobs").
    var blobReference: BlobReference? {
        guard let object = objectValue, let sha = object["$blob"]?.stringValue else { return nil }
        let size: Int64? = switch object["size"]?.normalized { case .int(let n): n; default: nil }
        return BlobReference(sha256: sha, size: size ?? 0, ext: object["ext"]?.stringValue)
    }
}

/// A file a field names, by its content hash.
struct BlobReference: Sendable, Hashable {
    var sha256: String
    var size: Int64
    var ext: String?

    var value: JSONValue {
        var object: [String: JSONValue] = ["$blob": .string(sha256), "size": .int(size)]
        if let ext { object["ext"] = .string(ext) }
        return .object(object)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int64.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = JSONValue.double(d).normalized }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

/// The one encoder every adapter goes through (§3, "Canonical encoding"): keys sorted at every
/// level, a `Set` as a sorted array, dates as integer milliseconds, no whitespace. The bytes are
/// what `JSON.stringify` makes of the same value with its object keys sorted (the service's
/// canonical form), so a diff or a tie compares the same text on both sides, and encoding the same
/// value twice never looks like a change.
enum CanonicalJSON {
    struct NotAnObject: Error {}

    // MARK: - Swift values to JSONValue

    /// Any `Encodable` as a JSON value, through the canonical rules.
    static func value<T: Encodable>(of item: T) throws -> JSONValue {
        try CanonicalBox.box(item, path: [])
    }

    /// An item's top-level keys: the record's fields.
    static func fields<T: Encodable>(of item: T) throws -> [String: JSONValue] {
        guard case .object(let object) = try value(of: item) else { throw NotAnObject() }
        return object
    }

    /// The fields, and the paths of any number that wasn't finite (NaN, infinity): those are
    /// written as `null`, as JSON.stringify does, and the caller logs them with the record's type
    /// and id.
    static func fieldsReporting<T: Encodable>(of item: T) throws -> (fields: [String: JSONValue], nonFinite: [String]) {
        let notes = EncodingNotes()
        let fields = try $notes.withValue(notes) { try self.fields(of: item) }
        return (fields, notes.nonFinite)
    }

    /// Where the encoder notes what it wrote as `null` for want of a finite number.
    @TaskLocal static var notes: EncodingNotes?

    final class EncodingNotes: @unchecked Sendable {
        private(set) var nonFinite: [String] = []
        func note(_ path: String) { nonFinite.append(path) }
    }

    /// The fields as a store's type, the way the canonical encoding wrote them (`null` reads as nil).
    static func decode<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        try decode(type, from: .object(fields))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data(value))
    }

    /// Parses JSON text.
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parseFields(_ text: String) -> [String: JSONValue] {
        (try? parse(Data(text.utf8)))?.objectValue ?? [:]
    }

    // MARK: - JSONValue to canonical text

    static func data(_ value: JSONValue) -> Data { Data(string(value).utf8) }

    static func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, to: &out)
        return out
    }

    static func string(_ fields: [String: JSONValue]) -> String { string(.object(fields)) }

    /// The tie order of §3: canonical text compared as UTF-8 bytes, `null` lowest. Negative when
    /// `a` sorts first.
    static func compare(_ a: JSONValue, _ b: JSONValue) -> Int {
        switch (a.isNull, b.isNull) {
        case (true, true): return 0
        case (true, false): return -1
        case (false, true): return 1
        default: break
        }
        let x = Array(string(a).utf8), y = Array(string(b).utf8)
        for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
        return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
    }

    /// Object keys in UTF-8 byte order (code point order), as the service sorts them
    /// (`compareText` in Service/src/space.js).
    static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func write(_ value: JSONValue, to out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i):
            // Beyond 2^53 the service holds the nearest double, and writes that. Compared as
            // integers: Double(2^53 + 1) rounds down to 2^53.
            out += i.magnitude <= JSONValue.exactIntegerMagnitude ? String(i) : number(Double(i))
        case .double(let d): out += number(d)
        case .string(let s): quote(s, to: &out)
        case .array(let items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                write(item, to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (n, key) in sortedKeys(object.keys).enumerated() {
                if n > 0 { out += "," }
                quote(key, to: &out)
                out += ":"
                write(object[key]!, to: &out)
            }
            out += "}"
        }
    }

    /// JSON.stringify's string escaping: `"` and `\`, the short escapes, other controls as \u00xx,
    /// everything else as itself.
    private static func quote(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// A double as JavaScript's `Number.prototype.toString` writes it (ECMA-262 Number::toString):
    /// the shortest digits that round-trip (Swift's `description` finds the same ones), laid out
    /// by JavaScript's rules: plain up to 21 integer digits, `0.000001` down to six leading zeros,
    /// otherwise `1.5e+21` / `1e-7`. Not-finite numbers are `null`, and -0 is `0`, as in
    /// JSON.stringify.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == 0 { return "0" }
        if d.rounded() == d, abs(d) <= JSONValue.exactIntegers { return String(Int64(d)) }
        var text = d.description
        var sign = ""
        if text.hasPrefix("-") { sign = "-"; text.removeFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        // text is now "123.456" or "123": digits, and where the point is.
        var integerPart = text, fraction = ""
        if let dot = text.firstIndex(of: ".") {
            integerPart = String(text[..<dot])
            fraction = String(text[text.index(after: dot)...])
        }
        var digits = integerPart + fraction
        var pointAt = integerPart.count + exponent   // n: the point sits after this many digits
        while digits.hasPrefix("0"), digits.count > 1 { digits.removeFirst(); pointAt -= 1 }
        while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
        let k = digits.count, n = pointAt
        let body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            body = digits[..<i] + "." + digits[i...]
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let exp = (e >= 0 ? "+" : "-") + String(abs(e))
            body = k == 1 ? digits + "e" + exp : digits.prefix(1) + "." + digits.dropFirst() + "e" + exp
        }
        return sign + body
    }
}

// MARK: - The encoder behind CanonicalJSON.value(of:)

/// Sets encode in no fixed order; this marks them so the encoder sorts their elements.
private protocol CanonicalUnordered {
    func canonicalElements(path: [CodingKey]) throws -> [JSONValue]
}

extension Set: CanonicalUnordered where Element: Encodable {
    fileprivate func canonicalElements(path: [CodingKey]) throws -> [JSONValue] {
        try map { try CanonicalBox.box($0, path: path) }
    }
}

/// One node of the tree an `Encodable` writes; resolved to a JSONValue at the end.
private class EncodedNode {
    func resolve() -> JSONValue { .null }
}

private final class LeafNode: EncodedNode {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    override func resolve() -> JSONValue { value }
}

private final class ObjectNode: EncodedNode {
    var children: [String: EncodedNode] = [:]
    override func resolve() -> JSONValue { .object(children.mapValues { $0.resolve() }) }
}

private final class ArrayNode: EncodedNode {
    var children: [EncodedNode] = []
    override func resolve() -> JSONValue { .array(children.map { $0.resolve() }) }
}

/// Whatever the value's `encode(to:)` chose to make: one value, an object or an array.
private final class SlotNode: EncodedNode {
    var inner: EncodedNode?
    override func resolve() -> JSONValue { inner?.resolve() ?? .object([:]) }
}

private struct IndexKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ index: Int) { stringValue = "Index \(index)"; intValue = index }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.init(intValue) }
}

private enum CanonicalBox {
    static func box<T: Encodable>(_ value: T, path: [CodingKey]) throws -> JSONValue {
        try node(value, path: path).resolve()
    }

    static func node<T: Encodable>(_ value: T, path: [CodingKey]) throws -> EncodedNode {
        switch value {
        case let json as JSONValue: return LeafNode(finite(json, path: path))
        case let date as Date: return LeafNode(.int(Int64((date.timeIntervalSince1970 * 1000).rounded())))
        case let data as Data: return LeafNode(.string(data.base64EncodedString()))
        case let url as URL: return LeafNode(.string(url.absoluteString))
        case let decimal as Decimal: return try LeafNode(double(NSDecimalNumber(decimal: decimal).doubleValue, path))
        case let set as CanonicalUnordered:
            let elements = try set.canonicalElements(path: path)
            return LeafNode(.array(elements.sorted { CanonicalJSON.compare($0, $1) < 0 }))
        default:
            let slot = SlotNode()
            try value.encode(to: CanonicalEncoder(path: path, slot: slot))
            return slot
        }
    }

    /// A JSON value handed over as it is, its non-finite numbers made `null` and noted.
    static func finite(_ value: JSONValue, path: [String]) -> JSONValue {
        switch value {
        case .double(let d) where !d.isFinite:
            CanonicalJSON.notes?.note(path.joined(separator: "."))
            return .null
        case .array(let items): return .array(items.enumerated().map { finite($1, path: path + ["\($0)"]) })
        case .object(let object): return .object(Dictionary(uniqueKeysWithValues: object.map { ($0, finite($1, path: path + [$0])) }))
        default: return value
        }
    }

    static func finite(_ value: JSONValue, path: [CodingKey]) -> JSONValue { finite(value, path: path.map(\.stringValue)) }

    /// A number that isn't finite is written as `null`, as JSON.stringify writes it, and noted.
    static func double(_ d: Double, _ path: [CodingKey]) throws -> JSONValue {
        guard d.isFinite else {
            CanonicalJSON.notes?.note(path.map(\.stringValue).joined(separator: "."))
            return .null
        }
        return JSONValue.double(d).normalizedForStorage
    }
}

private extension JSONValue {
    var normalizedForStorage: JSONValue { normalized }
}

private struct CanonicalEncoder: Encoder {
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    let slot: SlotNode

    init(path: [CodingKey], slot: SlotNode) {
        codingPath = path
        self.slot = slot
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let object: ObjectNode
        if let existing = slot.inner as? ObjectNode { object = existing } else { object = ObjectNode(); slot.inner = object }
        return KeyedEncodingContainer(KeyedContainer<Key>(codingPath: codingPath, object: object))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let array: ArrayNode
        if let existing = slot.inner as? ArrayNode { array = existing } else { array = ArrayNode(); slot.inner = array }
        return UnkeyedContainer(codingPath: codingPath, array: array)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleContainer(codingPath: codingPath, slot: slot)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [CodingKey]
    let object: ObjectNode

    private func put(_ value: JSONValue, _ key: Key) { object.children[key.stringValue] = LeafNode(value) }

    mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { put(try CanonicalBox.double(value, codingPath + [key]), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { put(try CanonicalBox.double(Double(value), codingPath + [key]), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { put(.int(value), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { put(unsigned(UInt64(value)), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { put(.int(Int64(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { put(unsigned(value), key) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        object.children[key.stringValue] = try CanonicalBox.node(value, path: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = ObjectNode()
        object.children[key.stringValue] = child
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(codingPath: codingPath + [key], object: child))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = ArrayNode()
        object.children[key.stringValue] = child
        return UnkeyedContainer(codingPath: codingPath + [key], array: child)
    }

    mutating func superEncoder() -> Encoder { superEncoder(named: "super") }
    mutating func superEncoder(forKey key: Key) -> Encoder { superEncoder(named: key.stringValue) }

    private func superEncoder(named name: String) -> Encoder {
        let slot = SlotNode()
        object.children[name] = slot
        return CanonicalEncoder(path: codingPath + [IndexKey(stringValue: name)!], slot: slot)
    }
}

private func unsigned(_ value: UInt64) -> JSONValue {
    value <= UInt64(Int64.max) ? .int(Int64(value)) : .double(Double(value))
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    var codingPath: [CodingKey]
    let array: ArrayNode
    var count: Int { array.children.count }

    private var nextPath: [CodingKey] { codingPath + [IndexKey(count)] }
    private func put(_ value: JSONValue) { array.children.append(LeafNode(value)) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(try CanonicalBox.double(value, nextPath)) }
    mutating func encode(_ value: Float) throws { put(try CanonicalBox.double(Double(value), nextPath)) }
    mutating func encode(_ value: Int) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { put(.int(value)) }
    mutating func encode(_ value: UInt) throws { put(unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt16) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt32) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt64) throws { put(unsigned(value)) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        array.children.append(try CanonicalBox.node(value, path: nextPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = ObjectNode()
        let path = nextPath
        array.children.append(child)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(codingPath: path, object: child))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = ArrayNode()
        let path = nextPath
        array.children.append(child)
        return UnkeyedContainer(codingPath: path, array: child)
    }

    mutating func superEncoder() -> Encoder {
        let slot = SlotNode()
        let path = nextPath
        array.children.append(slot)
        return CanonicalEncoder(path: path, slot: slot)
    }
}

private struct SingleContainer: SingleValueEncodingContainer {
    var codingPath: [CodingKey]
    let slot: SlotNode

    private func put(_ value: JSONValue) { slot.inner = LeafNode(value) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(try CanonicalBox.double(value, codingPath)) }
    mutating func encode(_ value: Float) throws { put(try CanonicalBox.double(Double(value), codingPath)) }
    mutating func encode(_ value: Int) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { put(.int(value)) }
    mutating func encode(_ value: UInt) throws { put(unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt16) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt32) throws { put(.int(Int64(value))) }
    mutating func encode(_ value: UInt64) throws { put(unsigned(value)) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        slot.inner = try CanonicalBox.node(value, path: codingPath)
    }
}
