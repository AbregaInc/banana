#!/usr/bin/env python3
"""Check actual Mail host cache membership with minimal non-UI adapter types."""
from pathlib import Path
import argparse,json,subprocess
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--reference-archive',type=Path);p.add_argument('--measure',action='store_true');a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
if a.measure and subprocess.run(['pgrep','-x','xcodebuild'],capture_output=True).returncode==0:
    (a.out/'report.json').write_text(json.dumps({'status':'unmeasured','reason':'Xcode is active; retain this attempt and retry when idle'}))
    raise SystemExit(2)
def method(path,start,end):
    file=(root/path) if a.reference_archive is None else a.reference_archive/(Path(path).stem+'-before.swift')
    s=file.read_text();return s[s.index(start):s.index(end,s.index(start))].replace('private func','func')
ios=method('Banana/Views/Mail/MailListHost+iOS.swift','    private func apply(_ shown:', '    func setStyle(')
mac=method('Banana/Views/Mail/MailListHost+Mac.swift','    private func load(_ shown:', '    private func apply(')
prelude='''import Foundation
typealias MailConversationID = Int
struct MailRow: Equatable { let id: Int; let title: String }
struct MailRowDisplay { let row: MailRow; init(_ row: MailRow, now: Date) { self.row = row } }
struct Session { let now = Date(timeIntervalSince1970: 0) }
struct NSDiffableDataSourceSnapshot<S: Hashable, I: Hashable> {
 var ids: [I] = []
 mutating func appendSections(_ values: [S]) {}
 mutating func appendItems(_ values: [I]) { ids += values }
 mutating func reconfigureItems(_ values: [I]) {}
}
final class DataSource {
 var completions: [() -> Void] = []
 func apply(_ snapshot: NSDiffableDataSourceSnapshot<Int, Int>, animatingDifferences: Bool, completion: (() -> Void)? = nil) {
  if let completion { completions.append(completion) }
 }
 func finish(_ index: Int) { if completions.indices.contains(index) { completions.remove(at: index)() } }
 func finishAll() { while !completions.isEmpty { finish(0) } }
}
'''
iosFields=method('Banana/Views/Mail/MailListHost+iOS.swift','    private var rows:', '    private var subscriptions:').replace('private var','var')
macFields=method('Banana/Views/Mail/MailListHost+Mac.swift','    private var order:', '    private var subscriptions:').replace('private var','var')
shared='let session = Session()\nlet dataSource = DataSource()\n'
source=prelude+'final class IOSHost {\n'+shared+iosFields+ios+'}\nfinal class MacHost {\n'+shared+macFields+mac+'}\n'+(Path(__file__).parent/'main.swift').read_text()
(a.out/'main.swift').write_text(source)
cmd=['swiftc','-O',str(a.out/'main.swift'),'-o',str(a.out/'checks')]
with (a.out/'build.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
result={'command':cmd,'buildExit':r.returncode}
if not r.returncode:
 with (a.out/'run.log').open('w') as f:r=subprocess.run([str((a.out/'checks').resolve()),str((a.out/'report.json').resolve())]+(['--measure'] if a.measure else []),stdout=f,stderr=subprocess.STDOUT)
 result['runExit']=r.returncode
(a.out/'command.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));raise SystemExit(r.returncode)
