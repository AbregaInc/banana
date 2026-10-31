#!/usr/bin/env python3
"""Pair real iPhone XCTest swipes with a bounded Hitches capture; retain partial/failing evidence."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', choices=['uniform-v1', 'varied-v1'], default='uniform-v1')
    parser.add_argument('--seed', type=int, default=20261009)
    parser.add_argument('--device',required=True,help='devicectl device identifier')
    parser.add_argument('--instruments-device',required=True,help='Instruments device name')
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--ablation',required=True)
    parser.add_argument('--presentation-policy', choices=['system', 'immediate', 'prefer120'])
    parser.add_argument('--density',type=int,default=300)
    parser.add_argument('--memo-raster-text', action='store_true')
    args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    scripts=Path(__file__).resolve().parent; touch=args.out/'touch';trace=args.out/'trace'
    state=dict(status='unmeasured',command=sys.argv,scope='Partial real-swipe trace; no input-to-visible acceptance')
    def save(): (args.out/'status.json').write_text(json.dumps(state,indent=2)+'\n')
    save()
    command=[sys.executable,str(scripts/'test-device-interactive.py'),'--device',args.device,
        '--out',str(touch),'--fixture',args.fixture,'--seed',str(args.seed),'--density',str(args.density),'--async-workers','2',
        '--ablation',args.ablation,'--skip-build',
        *(['--presentation-policy',args.presentation_policy] if args.presentation_policy else []),
        *(['--memo-raster-text'] if args.memo_raster_text else [])]
    with (args.out/'orchestration.log').open('w') as log:
        test=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
        began=time.monotonic();triggered=False
        try:
            while test.poll() is None and time.monotonic()-began<120:
                path=touch/'test.log'
                if path.exists() and 'Swipe up' in path.read_text(errors='replace'):
                    pid=json.loads((touch/'launch.json').read_text())['result']['process']['processIdentifier']
                    state.update(pid=pid,triggerTimestamp=datetime.datetime.now().astimezone().isoformat(),
                        trigger='First Swipe up in XCTest log; recorder attaches afterward')
                    save();triggered=True
                    profile=subprocess.run([sys.executable,str(scripts/'profile-device.py'),'--device',args.instruments_device,
                        '--pid',str(pid),'--out',str(trace),'--seconds','8'],stdout=log,stderr=subprocess.STDOUT,timeout=240)
                    state['profileExit']=profile.returncode;save();break
                time.sleep(.5)
            state['touchExit']=test.wait(timeout=300)
        except (subprocess.TimeoutExpired,KeyboardInterrupt) as error:
            state['error']=type(error).__name__
            test.terminate()
            try:test.wait(timeout=15)
            except subprocess.TimeoutExpired:test.kill();test.wait()
        state['captureTriggered']=triggered
        if state.get('touchExit')!=0 or state.get('profileExit')!=0:
            state['status']='failed-or-incomplete';save();return 2
        schemas=['hitches-updates','hitches-renders','hitches-gpu','hitches-frame-lifetimes','hitches',
            'display-vsyncs-interval','device-display-info','displayed-surfaces-interval','display-surface-swap']
        state['exports']=[]
        for schema in schemas:
            with (trace/(schema+'-export.log')).open('w') as export_log:
                try:
                    code=subprocess.run(['xcrun','xctrace','export','--input',str(trace/'touch.trace'),
                        '--xpath','/trace-toc/run[@number="1"]/data/table[@schema="'+schema+'"]',
                        '--output',str(trace/(schema+'.xml'))],stdout=export_log,stderr=subprocess.STDOUT,timeout=150).returncode
                except subprocess.TimeoutExpired:code=124
            state['exports'].append(dict(schema=schema,exitCode=code));save()
            if code:state['status']='failed-export';save();return 2
        analysis=subprocess.run([sys.executable,str(scripts/'report-hitches.py'),'--directory',str(trace),
            '--pid',str(state['pid']),'--out',str(trace/'analysis.json')],stdout=log,stderr=subprocess.STDOUT)
        state.update(status='captured-and-analyzed-partial-evidence',analysisExit=analysis.returncode)
        save();print(json.dumps(state,indent=2));return analysis.returncode


if __name__=='__main__':raise SystemExit(main())
