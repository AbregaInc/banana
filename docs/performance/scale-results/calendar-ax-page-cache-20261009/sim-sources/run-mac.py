#!/usr/bin/env python3
"""Native AppKit renderer matrix and one-at-a-time optimization ablations. Never certifies UI acceptance."""
import argparse, datetime, hashlib, json, pathlib, subprocess
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor
from report import summarize
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--raster', action='store_true', help='Append prerendered-page comparisons and cache/preparation ablations')
p.add_argument('--accessibility-only', action='store_true', help='Explicit subset: three paired trials of accessible-element retention versus rebuilding at both densities')
p.add_argument('--grid-only', action='store_true', help='Explicit subset: three paired trials of monolithic versus independent grid backing')
p.add_argument('--tiles-only', action='store_true', help='Explicit subset: three paired canvas/full-page/tile trials at both densities')
p.add_argument('--tile-ax-cache-only', action='store_true', help='Explicit subset: bounded same-event accessibility page retention')
p.add_argument('--tile-text-only', action='store_true', help='Explicit subset: budgeted tiles with and without invisible-text culling')
p.add_argument('--tile-cache-only', action='store_true', help='Explicit subset: tile prefetch LRU and capacity ablations')
p.add_argument('--tile-prefetch-only', action='store_true', help='Explicit subset: separately measure scroll/page/both tile prefetch at both densities')
a = p.parse_args()
if sum([a.grid_only, a.accessibility_only, a.tiles_only, a.tile_prefetch_only, a.tile_cache_only, a.tile_text_only, a.tile_ax_cache_only]) > 1: p.error('Choose one focused experiment')
a.out.mkdir(parents=True, exist_ok=False)
def command(*args):
    return subprocess.check_output(args, text=True, timeout=20).strip()
metadata = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), git=command('git','rev-parse','HEAD'),
    dirty=command('git','status','--porcelain'), binarySHA256=hashlib.sha256(a.binary.read_bytes()).hexdigest(),
    hostLoad=command('uptime'), os=command('sw_vers'), rasterComparisons=a.raster, accessibilityOnly=a.accessibility_only, gridOnly=a.grid_only, tilesOnly=a.tiles_only, tilePrefetchOnly=a.tile_prefetch_only, tileCacheOnly=a.tile_cache_only, tileTextOnly=a.tile_text_only, tileAXCacheOnly=a.tile_ax_cache_only, scope='Native AppKit synchronous work, not input/display acceptance')
(a.out/'environment.json').write_text(json.dumps(metadata,indent=2)+'\n')
cases = [('day',d,n,'canvas','none') for d,n in [(30,100),(365,100),(3650,100),(365,300)]]
cases += [('week',365,n,'canvas','none') for n in [100,300]]
# Matched controls are repeated beside each ablation to reveal load drift. No result is discarded.
for disabled in ['force-index','linear-lanes','force-heap','no-cache','no-prefetch','no-overscan','no-text-cache','no-text-prefetch','no-glyph-culling','full-surface','full-text-prefetch']:
    cases += [('week',365,100,'canvas','none'),('week',365,100,'canvas',disabled)]
cases += [('week',365,100,'cells','none'),('week',365,100,'cells','no-reuse')]
if a.raster:
    cases += [('day',d,n,'raster','none') for d,n in [(30,100),(365,100),(3650,100),(365,300)]]
    cases += [('week',365,n,'raster','none') for n in [100,300]]
    for density in [100,300]:
        for renderer,variant in [('raster','no-raster-cache'),('raster','no-raster-prefetch'),('raster','batch-raster-prefetch'),('canvas','full-text-prefetch')]:
            cases += [('week',365,density,renderer,'none'),('week',365,density,renderer,variant)]
if a.accessibility_only:
    cases = [('week',365,density,renderer,variant)
             for trial in range(3) for density in [100,300] for renderer in ['canvas','raster']
             for variant in (['rebuild-accessibility','none'] if trial % 2 == 0 else ['none','rebuild-accessibility'])]
if a.grid_only:
    cases = [('week',365,density,'canvas',variant) for trial in range(3) for density in [100,300]
             for variant in (['none','split-grid'] if trial % 2 == 0 else ['split-grid','none'])]
if a.tiles_only:
    cases = [('week',365,density,renderer,'none')
             for trial in range(3) for density in [100,300]
             for renderer in (['canvas','raster','tiles'] if trial % 2 == 0 else ['tiles','raster','canvas'])]
if a.tile_prefetch_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['none','tile-scroll-prefetch','tile-page-prefetch','tile-prefetch'] if trial % 2 == 0 else ['tile-prefetch','tile-page-prefetch','tile-scroll-prefetch','none'])]
if a.tile_cache_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch','tile-prefetch-lookahead','tile-prefetch-budgeted'] if trial % 2 == 0 else ['tile-prefetch-budgeted','tile-prefetch-lookahead','tile-prefetch'])]
if a.tile_text_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-budgeted','tile-prefetch-text-cull'] if trial % 2 == 0 else ['tile-prefetch-text-cull','tile-prefetch-budgeted'])]
if a.tile_ax_cache_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-budgeted','tile-prefetch-ax-cache'] if trial % 2 == 0 else ['tile-prefetch-ax-cache','tile-prefetch-budgeted'])]
rows=[]
for index,(mode,days,density,renderer,ablation) in enumerate(cases):
    name=f'{index:02d}-native-{mode}-{days}d-{density}perday-{renderer}-{ablation}'
    print('Measuring '+name,flush=True)
    with HostMonitor(a.out/(name+'-host.json')) as host:
        output=(a.out/(name+'.json')).resolve()
        before=command('uptime')
        args=[str(a.binary.resolve()),'--candidate','native','--mode',mode,'--days',str(days),'--density',str(density),
              '--renderer',renderer,'--ablation',ablation,'--output',str(output)]
        with (a.out/(name+'.log')).open('w') as log:
            try:
                process=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=90)
                exit_code=process.returncode
            except subprocess.TimeoutExpired:
                exit_code=124
        if output.exists():
            data=json.loads(output.read_text()); data['hostLoadBefore']=before; data['hostLoadAfter']=command('uptime')
            output.write_text(json.dumps(data,indent=2)+'\n')
            row=dict(scenario=name,exitCode=exit_code,**summarize(data))
            if data.get('optimizations') != dict(renderer=renderer,ablation=ablation): row['status']='invalid-policy'
        else:
            row=dict(scenario=name,status='failed-or-timeout',exitCode=exit_code,hostLoadBefore=before)
            output.write_text(json.dumps(row,indent=2)+'\n')
    row['hostMonitor'] = host.report()
    if row['status'] == 'measured' and not row['hostMonitor']['clean']: row['status'] = 'contended'
    rows.append(row); (a.out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
raise SystemExit(1 if any(r['status']!='measured' or r.get('acceptance')=='fail' or r.get('exitCode')!=0 for r in rows) else 2)
