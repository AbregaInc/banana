#!/usr/bin/env python3
"""Build and run paired GRDB SQL-cache probes on a selected booted Simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', type=Path, required=True, help='Completed Release Simulator build with GRDB.o')
    parser.add_argument('--device', required=True)
    parser.add_argument('--database', type=Path, required=True, help='Copied isolated stress podcast-catalog.sqlite; opened read-only')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    products = args.derived_data.resolve()/'Build/Products/Release-iphonesimulator'
    sqlite = args.derived_data.resolve()/'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite'
    source = Path(__file__).with_name('statement-cache.swift')
    binary = args.out.resolve()/'statement-cache'
    compile_command = ['xcrun','--sdk','iphonesimulator','swiftc','-O','-parse-as-library','-target','arm64-apple-ios26.1-simulator',
                       '-I',str(products),'-I',str(sqlite),str(source),str(products/'GRDB.o'),'-lsqlite3','-o',str(binary)]
    with (args.out/'build.log').open('w') as log:
        subprocess.run(compile_command, stdout=log, stderr=subprocess.STDOUT, check=True)
    summary = dict(status='incomplete', plannedCases=[f'{trial}-{mode}' for trial in range(3) for mode in (['uncached','cached'] if trial%2==0 else ['cached','uncached'])],
                   scope='Simulator SQL fetches, not app/UI acceptance', compileCommand=compile_command,
                   sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                   binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), device=args.device, cases=[])
    def save():
        (args.out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    save()
    with HostMonitor(args.out/'host.json') as monitor:
        for trial in range(3):
            for mode in (['uncached','cached'] if trial%2==0 else ['cached','uncached']):
                name=f'{trial}-{mode}'
                command=['xcrun','simctl','spawn',args.device,str(binary),str(args.database.resolve()),mode,
                         str(args.out.resolve()/(name+'.json')),'7']
                result=subprocess.run(command,capture_output=True,text=True,timeout=120)
                (args.out/(name+'.log')).write_text(result.stdout+result.stderr)
                summary['cases'].append(dict(name=name,command=command,exit=result.returncode));save()
                result.check_returncode()
                report=json.loads((args.out/(name+'.json')).read_text())
                if report.get('status') != 'passed-correctness' or report.get('cached') != (mode=='cached') or len(report.get('samples', [])) != 28 or report.get('checks') != 120:
                    raise RuntimeError(f'Incomplete or incorrect probe report: {name}')
    summary['host']=monitor.report()
    summary['status']='collected' if summary['host']['clean'] else 'unverified-host-activity'
    save()
    return 0 if summary['host']['clean'] else 2

if __name__ == '__main__':
    raise SystemExit(main())
