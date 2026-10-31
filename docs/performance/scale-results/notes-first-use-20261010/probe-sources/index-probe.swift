import Foundation
import GRDB
@main struct IndexProbe {
 static func main() throws {
  let a=CommandLine.arguments;precondition(a.count==4)
  let url=URL(fileURLWithPath:a[1]);let other=URL(fileURLWithPath:a[2]);let output=URL(fileURLWithPath:a[3])
  precondition(!FileManager.default.fileExists(atPath:output.path))
  let original=try OriginalNoteRepository(url:url,legacyURL:url.appendingPathExtension("absent"))
  let indexed=try IndexedNoteRepository(url:other,legacyURL:other.appendingPathExtension("absent"))
  let texts=["Café needle", "NEEDLE\0tail", "مراجعة needle", "顧客との打ち合わせ", "Straße", "İstanbul", "A \"quote\" here", "percent %_wild", "a\nbc needle", "résumé", "ﬁle", "a😃b", "x\u{1}needle", "foo bar", "foo-bar", "foo_bar", "a  b", "a.b"]
  let added=texts.enumerated().map { i,text -> VoiceNote in
   VoiceNote(id:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",i+1))!,createdAt:Date(timeIntervalSince1970:Double(i)),audioFilename:"",transcript:text,status:.transcribed)
  }
  _=try original.upsert(added);_=try indexed.upsert(added)
  let build=ProcessInfo.processInfo.systemUptime;try indexed.prepareProbeIndex();let buildMS=(ProcessInfo.processInfo.systemUptime-build)*1000
  let queries=["needle","NEEDLE","ordinary","missing","ne","Café","quote","\"quote\"","%_wild","\0","needle\0","Istanbul","STRASSE","file","foo bar","foo-bar","foo_bar","a  b","a.b","打ち合わせ","مراجعة"]
  var rows:[[String:Any]]=[];var checks=0
  for trial in 0..<3 {
   for query in queries {
    for archived in [false,true] {
     let expected=try original.page(search:query,archived:archived)
     for useIndex in trial.isMultiple(of:2) ? [false,true] : [true,false] {
      for state in ["released","warm"] {
       if state == "released" { if useIndex { indexed.releaseProbeMemory() } else { original.releaseProbeMemory() } }
       let start=ProcessInfo.processInfo.systemUptime
       let actual: (rows: [VoiceNote], total: Int)
       if useIndex { let page=try indexed.page(search:query,archived:archived);actual=(page.rows,page.total) }
       else { let page=try original.page(search:query,archived:archived);actual=(page.rows,page.total) }
       let ms=(ProcessInfo.processInfo.systemUptime-start)*1000
       precondition(actual.total==expected.total && actual.rows==expected.rows,"Mismatch: \(query)")
       checks += 1
       rows.append(["trial":trial,"query":query,"archived":archived,"indexed":useIndex,"state":state,"ms":ms,"total":actual.total,"rows":actual.rows.count])
      }
     }
    }
   }
  }
  var usage=rusage();getrusage(RUSAGE_SELF,&usage)
  let report:[String:Any]=["checks":checks,"indexBuildMS":buildMS,"samples":rows,"peakRSS":usage.ru_maxrss,
   "scope":"Isolated indexed candidate with real Foundation predicate/model decoding; Both SQLite caches explicitly released before released samples; OS cache remains warm. No app changes or migration/live-update acceptance."]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
  print("Passed \(checks) exact localized count/page/payload comparisons")
 }
}
