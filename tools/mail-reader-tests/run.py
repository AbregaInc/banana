#!/usr/bin/env python3
"""Test the actual reader's asynchronous body handoff without the app service graph."""
import argparse, hashlib, json, shutil, subprocess, re
from pathlib import Path
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path);a=p.parse_args()
a.out.mkdir(parents=True,exist_ok=False);target=a.out/'Tests';target.mkdir()
paths=[root/'Banana/Model/Mail'/name for name in ['MailContract.swift','MailSource+NotYet.swift','MailFileName.swift']]
paths += [root/'Banana/Model/MailUI/Pure'/name for name in ['MailReaderModel.swift','MailConversationFacts.swift','MailMessageDisplay.swift','MailAttachmentKind.swift','MailAttachmentText.swift','MailRowDisplay.swift','MailScheduleCopy.swift']]
paths += [root/'BananaTests/MailReaderModelTests.swift']
for path in paths: shutil.copy2(path,target/path.name)
toast=root/'Banana/Model/MailUI/Pure/MailToastText.swift';s=toast.read_text();start=s.index('    static func cleanSubject(');end=s.index('\n    /// How many characters',start)
(target/'MailToastExtract.swift').write_text(s[:s.index('enum MailToastText')]+'enum MailToastText {\n'+s[start:end]+'\n}\n')
opener=root/'Banana/Model/MailUI/Pure/MailComposerFiles.swift';s=opener.read_text();start=s.index('@MainActor\nfinal class MailAttachmentOpener')
(target/'MailAttachmentOpener.swift').write_text('import Foundation\nimport Combine\n'+s[start:])
(a.out/'source-sha256.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths+[toast,opener]},indent=2))
(a.out/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"MailReaderChecks",platforms:[.macOS(.v14)],targets:[.testTarget(name:"MailReaderChecks",path:"Tests",swiftSettings:[.swiftLanguageMode(.v5)])])
''')
cmd=['swift','test','--package-path',str(a.out.resolve()),'-c','release','--jobs','2']
with (a.out/'test.log').open('w') as f: r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
log=(a.out/'test.log').read_text()
passed=r.returncode == 0 and 'Executed 4 tests, with 0 failures' in log and not re.search(r'Test Case .* skipped',log)
(a.out/'status.json').write_text(json.dumps({'command':cmd,'exitCode':r.returncode,'passed':passed,'scope':'Reader correctness, not app or device performance acceptance'},indent=2))
print(f'Reader checks exited {r.returncode}: {a.out}/test.log');raise SystemExit(0 if passed else 1)
