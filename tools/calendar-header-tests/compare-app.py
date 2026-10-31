#!/usr/bin/env python3
"""Compare native Week header publication against its same-binary DEBUG control."""
from pathlib import Path
import argparse,hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[2]
CASES=[('rotation-0',['testReferenceWeekHeaderPublication'],True),
       ('rotation-1',['testNativeWeekRotation'],False),
       ('rotation-2',['testNativeWeekRotation'],False),
       ('rotation-3',['testReferenceWeekHeaderPublication'],True),
       ('integration',['testNativeWeekNavigation','testNativeWeekCalendarScroll','testNativeDayPagingAndZoom'],False)]
def verify(out):
    verdict={}
    for name,methods,reference in CASES:
        bundle=out/(name+'.xcresult')
        result=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],capture_output=True,text=True)
        if result.returncode:
            verdict[name]={'pass':False,'error':result.stderr};continue
        (out/(name+'-summary.json')).write_text(result.stdout)
        summary=json.loads(result.stdout)
        warnings=[w for w in summary.get('runtimeWarnings',[]) if 'Publishing changes from within view updates' in w.get('message','')]
        passed=(summary.get('result')=='Passed' and summary.get('totalTestCount')==len(methods)
                and summary.get('passedTests')==len(methods) and summary.get('skippedTests')==0
                and bool(warnings)==reference)
        verdict[name]={'pass':passed,'expectedPublicationWarning':reference,'publicationWarnings':len(warnings),
                       'result':summary.get('result'),'passedTests':summary.get('passedTests'),'skippedTests':summary.get('skippedTests')}
    result={'status':'pass' if all(v['pass'] for v in verdict.values()) else 'fail','cases':verdict,
            'scope':'Functional Simulator header delivery/warnings; not physical latency acceptance'}
    (out/'header-verdict.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    return 0 if result['status']=='pass' else 1

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--verify-only',action='store_true')
    p.add_argument('--device');p.add_argument('--derived-data',type=Path,default=ROOT/'.build/stress-dd')
    a=p.parse_args();out=a.out.resolve()
    if a.verify_only:return verify(out)
    if not a.device:p.error('--device is required when collecting')
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'],text=True))['devices']
    if not any(d['udid']==a.device and d['state']=='Booted' for group in devices.values() for d in group):
        p.error('--device must identify an already booted test Simulator')
    products=a.derived_data.resolve()/'Build/Products'
    runs=list(products.glob('Banana_iphonesimulator*-arm64.xctestrun'))
    if len(runs)!=1:p.error('Build Release + DEBUG for testing first; expected one arm64 xctestrun')
    app=products/'Release-iphonesimulator/Banana.app/Banana'
    if not app.is_file():p.error('Missing optimized app binary')
    out.mkdir(parents=True,exist_ok=False)
    sources=[ROOT/'Banana/Views/WeekView.swift',ROOT/'BananaUITests/ScaleStressUITests.swift',app]
    (out/'identity.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
    for name,methods,_ in CASES:
        cmd=['xcodebuild','-xctestrun',str(runs[0]),'-destination',f'platform=iOS Simulator,id={a.device},arch=arm64',
             '-parallel-testing-enabled','NO','-collect-test-diagnostics','never']
        cmd+=['-only-testing:BananaUITests/ScaleStressUITests/'+m for m in methods]
        cmd+=['-resultBundlePath',str(out/(name+'.xcresult')),'test-without-building']
        with (out/(name+'.log')).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
        (out/(name+'-exit.json')).write_text(json.dumps({'command':cmd,'exit':r.returncode},indent=2))
        if r.returncode:break
    return verify(out)
if __name__=='__main__':raise SystemExit(main())
