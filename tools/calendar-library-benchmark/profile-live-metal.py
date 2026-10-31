#!/usr/bin/env python3
"""Pair isolated Metal-preview XCTest with a partial physical Animation Hitches capture."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device',required=True); p.add_argument('--instruments-device',required=True)
    p.add_argument('--derived-data',required=True); p.add_argument('--out',type=Path,required=True)
    p.add_argument('--density',type=int,default=100)
    p.add_argument('--metal-display-link',action='store_true')
    p.add_argument('--release-on-gpu-completion',action='store_true')
    p.add_argument('--native-surfaces',action='store_true')
    p.add_argument('--presentation-policy', choices=['system','immediate','prefer120','both'], default='system')
    p.add_argument('--memo-text',action='store_true')
    p.add_argument('--capture-format',choices=['screenshots','screenRecording'])
    a=p.parse_args(); a.out.mkdir(parents=True,exist_ok=False)
    scripts=Path(__file__).resolve().parent; touch=a.out/'touch'; trace=a.out/'trace'
    state={'status':'unmeasured','scope':'Partial physical swipe capture; not full input-to-visible acceptance'}
    def save(): (a.out/'status.json').write_text(json.dumps(state,indent=2)+'\n')
    save()
    command=[sys.executable,str(scripts/'run-live-metal-device.py'),'--device',a.device,'--density',str(a.density),
             '--derived-data',a.derived_data,'--out',str(touch)]
    if a.metal_display_link: command.append('--metal-display-link')
    if a.release_on_gpu_completion: command.append('--release-on-gpu-completion')
    if a.capture_format: command += ['--capture-format',a.capture_format]
    if a.native_surfaces: command.append('--native-surfaces')
    if a.memo_text: command.append('--memo-text')
    if a.presentation_policy != 'system': command += ['--presentation-policy',a.presentation_policy]
    with (a.out/'orchestration.log').open('x') as log:
        process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+120
        while process.poll() is None and time.monotonic()<deadline:
            path=touch/'test.log'
            if path.exists() and 'Swipe up' in path.read_text(errors='replace'):
                pid=json.loads((touch/'launch.json').read_text())['result']['process']['processIdentifier']
                state.update(pid=pid,trigger='After first Swipe up appears in XCTest log'); save()
                profile=subprocess.run([sys.executable,str(scripts/'profile-device.py'),'--device',a.instruments_device,
                    '--pid',str(pid),'--out',str(trace),'--seconds','8'],stdout=log,stderr=subprocess.STDOUT,timeout=240)
                state['profileExit']=profile.returncode;save();break
            time.sleep(.5)
        try: state['runnerExit']=process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            process.terminate(); state['status']='runner-timeout';save();return 2
        result=json.loads((touch/'status.json').read_text())
        if result.get('status')!='functional-pass' or state.get('profileExit')!=0:
            state['status']='failed-or-incomplete';save();return 2
        schemas=['hitches-updates','hitches-renders','hitches-gpu','hitches-frame-lifetimes','hitches-framewait','hitches',
                 'display-vsyncs-interval','device-display-info','displayed-surfaces-interval','display-surface-swap']
        for schema in schemas:
            with (trace/(schema+'-export.log')).open('x') as output:
                r=subprocess.run(['xcrun','xctrace','export','--input',str(trace/'touch.trace'),'--xpath',
                    '/trace-toc/run[@number="1"]/data/table[@schema="'+schema+'"]','--output',str(trace/(schema+'.xml'))],
                    stdout=output,stderr=subprocess.STDOUT,timeout=150)
            if r.returncode:
                state.update(status='failed-export',schema=schema);save();return 2
        result=subprocess.run([sys.executable,str(scripts/'report-hitches.py'),'--directory',str(trace),
            '--pid',str(state['pid']),'--out',str(trace/'analysis.json')],stdout=log,stderr=subprocess.STDOUT)
        state.update(status='captured-partial-evidence',analysisExit=result.returncode);save()
        return result.returncode


if __name__=='__main__': raise SystemExit(main())
