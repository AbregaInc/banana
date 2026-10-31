import subprocess,pathlib,json,argparse,re
parser=argparse.ArgumentParser(description="Same-binary Calendar Day drag redraw ablation; not frame/input latency")
parser.add_argument("--device",required=True)
parser.add_argument("--xctestrun",required=True)
parser.add_argument("--out",required=True,type=pathlib.Path)
args=parser.parse_args()
root=args.out
root.mkdir(parents=True,exist_ok=False)
device=args.device
subprocess.run(['xcrun','simctl','uninstall',device,'com.boris.banana.uitests.xctrunner'],capture_output=True)
results=[]
for label,methods in [('parent-1',['testNativeDayParentMoveControl','testNativeDayParentLongMoveControl']),('local-1',['testNativeDayMoveFailure','testNativeDayMoveBeyondViewport']),('local-2',['testNativeDayMoveFailure','testNativeDayMoveBeyondViewport']),('parent-2',['testNativeDayParentMoveControl','testNativeDayParentLongMoveControl'])]:
    result=root/(label+'.xcresult')
    command=['xcodebuild','-xctestrun',args.xctestrun,'-destination',f'platform=iOS Simulator,id={device},arch=arm64','-parallel-testing-enabled','NO','-collect-test-diagnostics','never']
    command += ['-only-testing:BananaUITests/ScaleStressUITests/'+m for m in methods]
    command += ['-resultBundlePath',str(result),'test-without-building']
    with (root/(label+'.log')).open('w') as log:
        code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
    export=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(result)],capture_output=True,text=True)
    (root/(label+'-summary.json')).write_text(export.stdout)
    summary=json.loads(export.stdout) if export.returncode == 0 else {}
    samples=[dict(before=int(a),after=int(b),delta=int(b)-int(a),beyondViewport=c=="true")
             for a,b,c in re.findall(r"CALENDAR_MOVE_RENDERS before=(\d+) after=(\d+) beyondViewport=(true|false)",
                                    (root/(label+".log")).read_text())]
    valid=(code==0 and summary.get("passedTests")==2 and summary.get("failedTests")==0
           and summary.get("skippedTests")==0 and len(samples)==2)
    results.append(dict(label=label,exitCode=code,exportExitCode=export.returncode,
                        valid=valid,methods=methods,samples=samples))
    (root/'local-comparison-runs.json').write_text(json.dumps(results,indent=2))
    print(label,code,flush=True)

raise SystemExit(0 if all(r["valid"] for r in results) else 1)
