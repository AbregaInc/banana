import Foundation
import TantivySwift

struct Message: Decodable {
  let id: UInt64
  let subject, sender, snippet, body: String

  var recipients: String? = nil

  var fields: TantivyDocumentFields {
    var values = [
      DocumentField(name: "id", value: .u64(id)),
      DocumentField(name: "subject", value: .text(subject)),
      DocumentField(name: "sender", value: .text(sender)),
      DocumentField(name: "snippet", value: .text(snippet)),
      DocumentField(name: "body", value: .text(body)),
    ]
    if let recipients { values.append(DocumentField(name: "recipients", value: .text(recipients))) }
    return TantivyDocumentFields(fields: values)
  }
}

struct TaskQuery: Decodable { let id, query: String }
struct Measurement: Encodable {
  let id: String
  var keys: [UInt64]
  var ms: [Double]
}

func openIndex(_ path: String, fields: [String]) throws -> TantivyIndex {
  let schema = TantivySchemaBuilder()
  schema.addU64Field(
    name: "id",
    options: NumericFieldOptions(indexed: true, stored: false, fast: true, fieldnorms: false))
  for field in fields {
    schema.addTextField(
      name: field,
      options: TextFieldOptions(
        tokenizer: ["sender", "recipients"].contains(field) ? .default : .enStem,
        record: .withFreqs, stored: false, fast: false, fieldnorms: true))
  }
  return try TantivyIndex.newWithSchema(path: path, schemaBuilder: schema)
}

func queryExpression(_ text: String, preferCoverage: Bool) -> String {
  let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    .filter { !$0.isEmpty }
  let basic = words.joined(separator: " ")
  guard preferCoverage, !words.isEmpty else { return basic }
  var clauses = ["(" + basic + ")", "(" + words.joined(separator: " AND ") + ")"]
  if words.count <= 2 {
    for field in ["subject", "sender", "snippet"] {
      clauses.append("(" + words.map { field + ":" + $0 }.joined(separator: " AND ") + ")")
    }
  }
  return clauses.joined(separator: " OR ")
}

func rankedIDs(
  _ text: String, index: TantivyIndex, fields: [String], preferCoverage: Bool, limit: UInt32
) throws -> [UInt64] {
  let expression = queryExpression(text, preferCoverage: preferCoverage)
  let query = TantivySearchQuery(
    queryStr: expression, defaultFields: fields, fuzzyFields: [],
    topDocLimit: limit, topDocOffset: 0)
  let hits = try index.searchDocIds(query: query, idField: "id")
  var seen = Set<UInt64>()
  var keys: [UInt64] = []
  for hit in hits where seen.insert(hit.docId).inserted {
    keys.append(hit.docId)
    if keys.count == 50 { break }
  }
  return keys
}

func run() throws {
  let args = Array(CommandLine.arguments.dropFirst())
  guard args.count >= 2 else { throw CocoaError(.fileReadInvalidFileName) }
  let full = ["build-full", "full"].contains(args[0])
  let fields = ["subject", "sender", "snippet", "body"] + (full ? ["recipients"] : [])
  let index = try openIndex(args[1], fields: fields)
  let decoder = JSONDecoder()
  if ["build", "build-full"].contains(args[0]) {
    guard index.docsCount() == 0 else { throw CocoaError(.fileWriteFileExists) }
    var batch: [TantivyDocumentFields] = []
    var count = 0
    while let line = readLine() {
      let message = try decoder.decode(Message.self, from: Data(line.utf8))
      batch.append(message.fields)
      count += 1
      if batch.count == 512 {
        try index.indexDocs(docs: batch)
        batch.removeAll(keepingCapacity: true)
      }
    }
    if !batch.isEmpty { try index.indexDocs(docs: batch) }
    try index.commit()
    guard index.docsCount() == UInt64(count) else { throw CocoaError(.fileReadCorruptFile) }
    print(count)
  } else if args[0] == "lifecycle" {
    guard index.docsCount() == 0 else { throw CocoaError(.fileWriteFileExists) }
    let initial = Message(id: 1, subject: "itinerary", sender: "", snippet: "", body: "")
    let revised = Message(id: 1, subject: "refund", sender: "", snippet: "", body: "")
    func matches(_ text: String) throws -> [UInt64] {
      try rankedIDs(text, index: index, fields: fields, preferCoverage: true, limit: 50)
    }
    try index.indexDocs(docs: [initial.fields])
    try index.commit()
    guard try matches("itinerary") == [1] else { throw CocoaError(.fileReadCorruptFile) }
    try index.deleteDoc(id: DocumentField(name: "id", value: .u64(1)))
    try index.indexDocs(docs: [revised.fields])
    try index.commit()
    guard try matches("itinerary").isEmpty, try matches("refund") == [1] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try index.deleteDoc(id: DocumentField(name: "id", value: .u64(1)))
    guard try matches("refund").isEmpty, index.docsCount() == 0 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    print("Insert, commit, replace and delete verified")
  } else if ["search", "coverage", "full"].contains(args[0]), args.count == 4 {
    let tasks = try decoder.decode(
      [TaskQuery].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    var measures = tasks.map { Measurement(id: $0.id, keys: [], ms: []) }
    for trial in 0..<3 {
      for offset in tasks.indices {
        let i = (offset + trial * 31) % tasks.count
        let start = DispatchTime.now().uptimeNanoseconds
        let keys = try rankedIDs(
          tasks[i].query, index: index, fields: fields, preferCoverage: args[0] != "search",
          limit: full ? 200 : 50)
        measures[i].ms.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        if trial == 0 {
          measures[i].keys = keys
        } else if measures[i].keys != keys {
          throw CocoaError(.fileReadCorruptFile)
        }
      }
    }
    try JSONEncoder().encode(measures).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
  } else {
    throw CocoaError(.fileReadInvalidFileName)
  }
}
try run()
