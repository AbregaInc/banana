import Foundation
let texts=["Café needle", "NEEDLE\0tail", "مراجعة needle", "顧客との打ち合わせ", "Straße", "İstanbul", "A \"quote\" here", "percent %_wild", "a\nbc needle", "résumé", "ﬁle", "a😃b", "x\u{1}needle", "foo bar", "foo-bar", "foo_bar", "a  b", "a.b"]
let queries=["needle","NEEDLE","ordinary","missing","ne","Café","quote","\"quote\"","%_wild","\0","Istanbul","STRASSE","file","foo bar","foo-bar","foo_bar","a  b","a.b","打ち合わせ","مراجعة"]
precondition(CommandLine.arguments.count==2)
let output=CommandLine.arguments[1];precondition(!FileManager.default.fileExists(atPath:output))
var checks=0
for q in queries {for t in texts {
 precondition(t.localizedCaseInsensitiveContains(q)==(t as NSString).localizedCaseInsensitiveContains(q));checks+=1
}}
precondition(("Café needle" as NSString).localizedCaseInsensitiveContains("needle\0"));checks+=1
precondition(!("Café needle" as NSString).localizedCaseInsensitiveContains("missing\0"));checks+=1
let notes = texts.map { VoiceNote(audioFilename: "", transcript: $0, status: .transcribed) }
let cache = NoteQueryCache()
for q in queries {
 let expected = notes.filter { $0.transcript!.localizedCaseInsensitiveContains(q) }.map(\.id)
 precondition(cache.matching(notes, search: q, archived: false).map(\.id) == expected)
 checks += 1
}
let fields = [
 VoiceNote(audioFilename: "", transcript: "Café needle", status: .transcribed),
 VoiceNote(audioFilename: "", context: .init(episodeTitle: "Café needle"), status: .transcribed),
 VoiceNote(audioFilename: "", context: .init(podcastTitle: "Café needle"), status: .transcribed),
 VoiceNote(audioFilename: "", context: .init(transcriptExcerpt: "Café needle"), status: .transcribed)]
cache.invalidate()
precondition(cache.matching(fields, search: "needle\0", archived: false).map(\.id) == fields.map(\.id)); checks += 1
precondition(cache.matching(fields, search: "missing\0", archived: false).isEmpty); checks += 1
var samples:[[String:Any]]=[];var sink=0
for i in 0..<20 {
 for native in i.isMultiple(of:2) ? [false,true] : [true,false] {
  let start=ProcessInfo.processInfo.systemUptime
  for _ in 0..<10 { for q in queries { for t in texts {
   if native ? (t as NSString).localizedCaseInsensitiveContains(q) : t.localizedCaseInsensitiveContains(q) {sink+=1}
  }}}
  samples.append(["native":native,"ms":(ProcessInfo.processInfo.systemUptime-start)*1000])
 }
}
try JSONSerialization.data(withJSONObject:["checks":checks,"samples":samples,"comparisonsPerSample":3600,"sink":sink,"scope":"Foundation matching API only, warmed by correctness checks; not repository or UI timings."],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
print("Passed \(checks) checks")
