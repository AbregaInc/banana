#!/usr/bin/env python3
"""Measure the shipping MailRowDisplay formatter, including preparation after eviction."""
import argparse, hashlib, json, platform, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--checks-only', action='store_true', help='Run output/lifecycle checks without collecting timings')
p.add_argument('--formatter-pool', action='store_true', help='Experiment only: bounded native formatter reuse')
p.add_argument('--format-style', action='store_true', help='Experiment only: replace date templates in the copied source')
a = p.parse_args()
if a.format_style and a.formatter_pool: p.error('select one experiment')
if a.checks_only and not (a.format_style or a.formatter_pool): p.error('checks-only needs a comparison experiment')
a.out.mkdir(parents=True, exist_ok=False)
if not a.checks_only and subprocess.run(['pgrep', '-x', 'xcodebuild'], capture_output=True).returncode == 0:
    (a.out / 'report.json').write_text(json.dumps({'status': 'unmeasured', 'reason': 'Xcode is active'}))
    raise SystemExit(2)
paths = [root / 'Banana/Model/Mail/MailContract.swift',
         root / 'Banana/Model/MailUI/Pure/MailRowDisplay.swift',
         root / 'Banana/Model/MailUI/Pure/MailScheduleCopy.swift']
# Compile the actual subject cleaner and toast value; the remaining toast actions depend
# on the triage model and are unrelated to row preparation. No display/row adapters.
toast = root / 'Banana/Model/MailUI/Pure/MailToastText.swift'
s = toast.read_text()
start = s.index('    static func cleanSubject(')
end = s.index('\n    /// How many characters', start)
(a.out / 'MailToastExtract.swift').write_text(s[:s.index('enum MailToastText')] + 'enum MailToastText {\n' + s[start:end] + '\n}\n')
for path in paths:
    (a.out / path.name).write_bytes(path.read_bytes())
(a.out / 'main.swift').write_bytes((Path(__file__).parent / 'main.swift').read_bytes())
if a.checks_only:
    main = a.out / 'main.swift'
    main.write_text(main.read_text().split('var measurements:', 1)[0])
extra_sources = []
if a.format_style or a.formatter_pool:
    display = a.out / 'MailRowDisplay.swift'
    original = display.read_text()
    reference = a.out / 'ReferenceMailRowDisplay.swift'
    reference.write_text(original.replace('MailRowDisplay', 'ReferenceMailRowDisplay').replace('MailDateText', 'ReferenceMailDateText'))
    start = original.index('        let formatter = DateFormatter()', original.index('private static func format('))
    end = original.index('        return formatter.string(from: date)', start) + len('        return formatter.string(from: date)')
    body = """        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        switch template {
        case "jmm": return style.hour().minute().format(date)
        case "EEE": return style.weekday(.abbreviated).format(date)
        case "dMMM": return style.day().month(.abbreviated).format(date)
        case "dMMMyyyy": return style.day().month(.abbreviated).year().format(date)
        case "EEEdMMMjmm": return style.weekday(.abbreviated).day().month(.abbreviated).hour().minute().format(date)
        default: preconditionFailure("Uncovered template: \(template)")
        }"""
    if a.formatter_pool:
        body = '        return MailDateFormatterPool.shared.string(template, date, calendar, locale)'
        pool = a.out / 'FormatterPool.swift'
        pool.write_bytes((Path(__file__).parent / 'FormatterPool.swift').read_bytes())
        extra_sources.append(str(pool))
    display.write_text(original[:start] + body + original[end:])
    extra_sources.append(str(reference))
    main = a.out / 'main.swift'
    main.write_text(main.read_text() + '\n' + (Path(__file__).parent / 'parity.swift').read_text())
    if a.formatter_pool:
        main.write_text(main.read_text() + '\n' + (Path(__file__).parent / 'pool-checks.swift').read_text())
manifest = {'sources': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in paths + [toast]}, 'platform': platform.platform(), 'checksOnly': a.checks_only, 'experiment': 'formatter-pool' if a.formatter_pool else ('format-style' if a.format_style else 'shipping')}
cmd = ['swiftc', '-O'] + [str(a.out / path.name) for path in paths] + [str(a.out / 'MailToastExtract.swift'), str(a.out / 'main.swift')] + extra_sources + ['-o', str(a.out / 'probe')]
with (a.out / 'build.log').open('w') as f:
    r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
manifest.update(command=cmd, buildExit=r.returncode)
if r.returncode == 0:
    with (a.out / 'run.log').open('w') as f:
        r = subprocess.run([str((a.out / 'probe').resolve()), str((a.out / 'report.json').resolve())], stdout=f, stderr=subprocess.STDOUT)
    manifest['runExit'] = r.returncode
(a.out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest))
raise SystemExit(r.returncode)
