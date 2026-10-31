#!/usr/bin/env python3
"""Run pinned calendar renderer component probes; never claims frame/input acceptance."""
import argparse, datetime, hashlib, json, pathlib, subprocess, time, uuid
from report import summarize
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True, help='Already-booted dedicated Simulator UDID')
p.add_argument('--app', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--candidates', nargs='+', choices=['ck','kvk','native'], default=['ck','kvk','native'], help='Default retains all original library cases plus native cases; subsets are explicitly recorded')
p.add_argument('--ablations', action='store_true', help='Append matched native optimization controls/variants; keep the original comparison cases')
p.add_argument('--cells', action='store_true', help='Append all six native event-view history/density cases')
p.add_argument('--raster', action='store_true', help='Append prerendered-page comparisons and cache/preparation ablations')
p.add_argument('--accessibility-only', action='store_true', help='Explicit native subset: three paired accessibility-retention trials at both densities')
p.add_argument('--grid-only', action='store_true', help='Explicit subset: three paired trials of monolithic versus independent grid backing')
p.add_argument('--tiles-only', action='store_true', help='Explicit subset: three paired canvas/full-page/tile trials at both densities')
a = p.parse_args()
if sum([a.grid_only, a.accessibility_only, a.tiles_only]) > 1: p.error('Choose one focused experiment')
if (a.ablations or a.raster or a.cells or a.accessibility_only or a.grid_only or a.tiles_only) and 'native' not in a.candidates: p.error('--ablations requires the native candidate')
a.out.mkdir(parents=True, exist_ok=False)
bundle = 'com.boris.banana.calendar-library-benchmark'
def call(*args, check=True):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=check, timeout=60)
    except subprocess.TimeoutExpired as error:
        if check:
            raise
        output = error.stdout or b''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        return subprocess.CompletedProcess(args, 124, output, 'Command timed out after 60 seconds\n')
call('xcrun', 'simctl', 'install', a.device, str(a.app.resolve()))
container = pathlib.Path(call('xcrun', 'simctl', 'get_app_container', a.device, bundle, 'data').stdout.strip())
metadata = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), device=a.device,
                app=str(a.app.resolve()), git=call('git','rev-parse','HEAD').stdout.strip(),
                xcode=call('xcodebuild','-version').stdout.strip(), hostLoad=call('uptime').stdout.strip(),
                binarySHA256=hashlib.sha256((a.app/'CalendarLibraryBenchmark').read_bytes()).hexdigest(),
                candidates=a.candidates, accessibilityOnly=a.accessibility_only, gridOnly=a.grid_only, tilesOnly=a.tiles_only, ablations=a.ablations, rasterComparisons=a.raster, cellComparisons=a.cells, scope='Simulator synchronous renderer work; not frame/input acceptance')
(a.out/'environment.json').write_text(json.dumps(metadata,indent=2)+'\n')
cases = [(c,'day',d,n,'bounded') for d,n in [(30,100),(365,100),(3650,100),(365,300)] for c in a.candidates]
for density in [100,300]:
    for candidate in ['kvk','native']:
        if candidate in a.candidates:
            cases.append((candidate,'week',365,density,'bounded'))
            if candidate == 'kvk' and density == 100: cases.append((candidate,'week',365,density,'full'))
cases = [(c,m,d,n,f,'canvas','none','') for c,m,d,n,f in cases]
if a.ablations:
    for index, disabled in enumerate(['force-index','linear-lanes','force-heap','no-cache','no-prefetch','no-overscan','no-text-cache','no-text-prefetch','no-glyph-culling','full-surface','full-text-prefetch']):
        for variant in ['none', disabled]:
            cases.append(('native','week',365,100,'bounded','canvas',variant,f'-ablation{index}-{variant}'))
    cases += [('native','week',365,100,'bounded','cells',variant,f'-cells-{variant}') for variant in ['none','no-reuse']]
if a.cells:
    cases += [('native',m,d,n,'bounded','cells','none','-cells-matrix') for m,d,n in
              [('day',30,100),('day',365,100),('day',3650,100),('day',365,300),('week',365,100),('week',365,300)]]
if a.raster:
    cases += [('native',m,d,n,'bounded','raster','none','-raster') for m,d,n in
              [('day',30,100),('day',365,100),('day',3650,100),('day',365,300),('week',365,100),('week',365,300)]]
    for density in [100,300]:
        for renderer,disabled in [('raster','no-raster-cache'),('raster','no-raster-prefetch'),('raster','batch-raster-prefetch'),('canvas','full-text-prefetch')]:
            for variant in ['none',disabled]:
                cases.append(('native','week',365,density,'bounded',renderer,variant,f'-{renderer}-{disabled}-pair-{variant}'))
if a.accessibility_only:
    cases = [('native','week',365,density,'bounded',renderer,variant,f'-ax-{trial}-{renderer}-{variant}')
             for trial in range(3) for density in [100,300] for renderer in ['canvas','raster']
             for variant in (['rebuild-accessibility','none'] if trial % 2 == 0 else ['none','rebuild-accessibility'])]
if a.grid_only:
    cases = [('native','week',365,density,'bounded','canvas',variant,f'-grid-{trial}-{variant}')
             for trial in range(3) for density in [100,300]
             for variant in (['none','split-grid'] if trial % 2 == 0 else ['split-grid','none'])]
if a.tiles_only:
    cases = [('native','week',365,density,'bounded',renderer,'none',f'-tiles-{trial}-{renderer}')
             for trial in range(3) for density in [100,300]
             for renderer in (['canvas','raster','tiles'] if trial % 2 == 0 else ['tiles','raster','canvas'])]
summary=[]
for candidate, mode, days, density, feed, renderer, ablation, suffix in cases:
    name=f'{candidate}-{mode}-{days}d-{density}perday-{feed}{suffix}'
    print('Measuring '+name,flush=True)
    call('xcrun','simctl','terminate',a.device,bundle,check=False)
    filename='result-'+str(uuid.uuid4())+'.json'
    loadBefore=call('uptime').stdout.strip()
    started=time.monotonic()
    launch=call('xcrun','simctl','launch',a.device,bundle,'--candidate',candidate,'--mode',mode,
                '--days',str(days),'--density',str(density),'--feed',feed,'--renderer',renderer,'--ablation',ablation,'--output',filename,check=False)
    (a.out/(name+'-launch.log')).write_text(launch.stdout+launch.stderr)
    result=container/'Documents'/filename
    while launch.returncode==0 and not result.exists() and time.monotonic()-started < 90:
        time.sleep(.5)
    if not result.exists():
        row=dict(scenario=name,status='failed-or-timeout',launchExit=launch.returncode,
                 elapsedSeconds=time.monotonic()-started, hostLoadBefore=loadBefore,
                 resultFilename=filename)
        (a.out/(name+'.json')).write_text(json.dumps(row,indent=2)+'\n')
    else:
        data=json.loads(result.read_text())
        data['hostLoadBefore']=loadBefore
        data['hostLoadAfter']=call('uptime').stdout.strip()
        (a.out/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
        row=dict(scenario=name, **summarize(data))
        if candidate == 'native' and data.get('optimizations') != dict(renderer=renderer,ablation=ablation): row['status']='invalid-policy'
    summary.append(row)
    (a.out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
call('xcrun','simctl','terminate',a.device,bundle,check=False)
print('Artifacts: '+str(a.out),flush=True)
raise SystemExit(1 if any(r.get('acceptance')=='fail' or r['status']!='measured' for r in summary) else 2)
