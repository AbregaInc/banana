#!/usr/bin/env python3
"""Native AppKit renderer matrix and one-at-a-time optimization ablations. Never certifies UI acceptance."""
import argparse, datetime, hashlib, json, pathlib, subprocess
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor
from report import summarize
from fixture_policy import matches_fixture
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--raster', action='store_true', help='Append prerendered-page comparisons and cache/preparation ablations')
p.add_argument('--accessibility-only', action='store_true', help='Explicit subset: three paired trials of accessible-element retention versus rebuilding at both densities')
p.add_argument('--grid-only', action='store_true', help='Explicit subset: three paired trials of monolithic versus independent grid backing')
p.add_argument('--tiles-only', action='store_true', help='Explicit subset: three paired canvas/full-page/tile trials at both densities')
p.add_argument('--tile-native-text-only', action='store_true', help='Explicit subset: native Core Text line drawing inside raster jobs')
p.add_argument('--tile-queue-only', action='store_true', help='Explicit subset: Task prefetch versus native operation queue with one/two workers')
p.add_argument('--tile-queue-cancel-only', action='store_true', help='Explicit subset: two-worker queue with and without cooperative drawing cancellation')
p.add_argument('--tile-ax-cache-only', action='store_true', help='Explicit subset: bounded same-event accessibility page retention')
p.add_argument('--foreground-surface-properties-only', action='store_true', help='Native surface with framework versus stored accessibility properties')
p.add_argument('--foreground-surface-cache-only', action='store_true', help='Native surface contents with eager versus retained event accessibility')
p.add_argument('--foreground-surface-only', action='store_true', help='CGImage versus native surface-backed CVPixelBuffer contents')
p.add_argument('--foreground-layer-only', action='store_true', help='Native AppKit draw backing versus updateLayer for explicit bitmap sublayers')
p.add_argument('--foreground-only', action='store_true', help='Three alternating trials of synchronous/one-worker/two-worker foreground preparation')
p.add_argument('--foreground-navigation', action='store_true', help='Append complete foreground paging phase measurements')
p.add_argument('--navigation-stress', action='store_true', help='Append forward/return and 32 ms rapid paging coverage')
p.add_argument('--tile-text-only', action='store_true', help='Explicit subset: budgeted tiles with and without invisible-text culling')
p.add_argument('--tile-cache-only', action='store_true', help='Explicit subset: tile prefetch LRU and capacity ablations')
p.add_argument('--tile-prefetch-only', action='store_true', help='Explicit subset: separately measure scroll/page/both tile prefetch at both densities')
p.add_argument('--fixture', choices=['uniform-v1', 'varied-v1'], default='uniform-v1')
p.add_argument('--seed', type=int, default=20261009)
p.add_argument('--hidden-calendars', default='')
p.add_argument('--batch-event-fills', action='store_true', help='Experimental fill batching; acceptance remains subject to tail latency')
p.add_argument('--memo-raster-text', action='store_true')
a = p.parse_args()
if a.memo_raster_text and a.tile_native_text_only: p.error('Text memo targets prepared glyphs, not native CTLine')
if (a.foreground_only or a.foreground_layer_only or a.foreground_surface_only or a.foreground_surface_cache_only or a.foreground_surface_properties_only) and not a.foreground_navigation: p.error('--foreground-only requires --foreground-navigation')
if sum([a.grid_only, a.accessibility_only, a.tiles_only, a.tile_prefetch_only, a.tile_cache_only, a.tile_text_only, a.tile_ax_cache_only, a.tile_native_text_only, a.tile_queue_only, a.tile_queue_cancel_only, a.foreground_only, a.foreground_layer_only, a.foreground_surface_only, a.foreground_surface_cache_only, a.foreground_surface_properties_only]) > 1: p.error('Choose one focused experiment')
a.out.mkdir(parents=True, exist_ok=False)
def command(*args):
    return subprocess.check_output(args, text=True, timeout=20).strip()
metadata = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), git=command('git','rev-parse','HEAD'),
    dirty=command('git','status','--porcelain'), binarySHA256=hashlib.sha256(a.binary.read_bytes()).hexdigest(),
    hostLoad=command('uptime'), os=command('sw_vers'), rasterComparisons=a.raster, accessibilityOnly=a.accessibility_only, gridOnly=a.grid_only, tilesOnly=a.tiles_only, tilePrefetchOnly=a.tile_prefetch_only, tileCacheOnly=a.tile_cache_only, tileTextOnly=a.tile_text_only, tileAXCacheOnly=a.tile_ax_cache_only, tileNativeTextOnly=a.tile_native_text_only, tileQueueOnly=a.tile_queue_only, tileQueueCancelOnly=a.tile_queue_cancel_only, navigationStress=a.navigation_stress, foregroundNavigation=a.foreground_navigation, foregroundOnly=a.foreground_only, foregroundLayerOnly=a.foreground_layer_only, foregroundSurfaceOnly=a.foreground_surface_only, foregroundSurfaceCacheOnly=a.foreground_surface_cache_only, foregroundSurfacePropertiesOnly=a.foreground_surface_properties_only, scope='Native AppKit synchronous work, not input/display acceptance')
metadata.update(memoRasterText=a.memo_raster_text, batchEventFills=a.batch_event_fills, fixture=a.fixture, seed=str(a.seed), hiddenCalendars=a.hidden_calendars)
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
if a.tile_native_text_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-budgeted','tile-prefetch-native-text'] if trial % 2 == 0 else ['tile-prefetch-native-text','tile-prefetch-budgeted'])]
if a.tile_queue_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-budgeted','tile-prefetch-queue-one','tile-prefetch-queue-two'] if trial % 2 == 0 else ['tile-prefetch-queue-two','tile-prefetch-queue-one','tile-prefetch-budgeted'])]
if a.tile_queue_cancel_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-queue-two','tile-prefetch-queue-two-cancel'] if trial % 2 == 0 else ['tile-prefetch-queue-two-cancel','tile-prefetch-queue-two'])]
if a.foreground_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-budgeted','tile-prefetch-async-one','tile-prefetch-async-two'] if trial % 2 == 0 else ['tile-prefetch-async-two','tile-prefetch-async-one','tile-prefetch-budgeted'])]
if a.foreground_layer_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-async-two','tile-prefetch-async-layer'] if trial % 2 == 0 else ['tile-prefetch-async-layer','tile-prefetch-async-two'])]
if a.foreground_surface_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-async-two','tile-prefetch-async-surface'] if trial % 2 == 0 else ['tile-prefetch-async-surface','tile-prefetch-async-two'])]
if a.foreground_surface_cache_only:
    cases = [('week',365,density,'tiles',variant)
             for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-async-surface','tile-prefetch-async-surface-cache'] if trial % 2 == 0 else ['tile-prefetch-async-surface-cache','tile-prefetch-async-surface'])]
if a.foreground_surface_properties_only:
    cases = [('week',365,density,'tiles',variant) for trial in range(3) for density in [100,300]
             for variant in (['tile-prefetch-async-surface','tile-prefetch-async-surface-properties'] if trial % 2 == 0 else ['tile-prefetch-async-surface-properties','tile-prefetch-async-surface'])]
rows=[]
for index,(mode,days,density,renderer,ablation) in enumerate(cases):
    name=f'{index:02d}-native-{mode}-{days}d-{density}perday-{renderer}-{ablation}'
    print('Measuring '+name,flush=True)
    with HostMonitor(a.out/(name+'-host.json')) as host:
        output=(a.out/(name+'.json')).resolve()
        before=command('uptime')
        args=[str(a.binary.resolve()),'--candidate','native','--mode',mode,'--days',str(days),'--density',str(density),
              '--renderer',renderer,'--ablation',ablation,'--output',str(output),
              '--fixture',a.fixture,'--seed',str(a.seed),'--hidden-calendars',a.hidden_calendars]
        if a.memo_raster_text: args.append('--memo-raster-text')
        if a.batch_event_fills: args.append('--batch-event-fills')
        if a.navigation_stress: args.append('--navigation-stress')
        if a.foreground_navigation: args.append('--foreground-navigation')
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
            if any(data.get(key) != value for key, value in dict(mode=mode, days=days,
                    eventsPerDay=density, retainedEvents=days*density).items()): row['status']='invalid-workload'
            if data.get('optimizations') != dict(renderer=renderer,ablation=ablation): row['status']='invalid-policy'
            if not matches_fixture(data, a.fixture, a.seed, a.hidden_calendars): row['status']='invalid-fixture'
            if bool(data.get('memoRasterText')) != a.memo_raster_text: row['status']='invalid-text-memo-policy'
            if bool(data.get('batchEventFills')) != a.batch_event_fills: row['status']='invalid-fill-policy'
            if bool(data.get('navigationStress')) != a.navigation_stress: row['status']='invalid-navigation-policy'
            if bool(data.get('foregroundNavigation')) != a.foreground_navigation: row['status']='invalid-foreground-policy'
        else:
            row=dict(scenario=name,status='failed-or-timeout',exitCode=exit_code,hostLoadBefore=before)
            output.write_text(json.dumps(row,indent=2)+'\n')
    row['hostMonitor'] = host.report()
    if row['status'] == 'measured' and not row['hostMonitor']['clean']: row['status'] = 'contended'
    rows.append(row); (a.out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
raise SystemExit(1 if any(r['status']!='measured' or r.get('acceptance')=='fail' or r.get('exitCode')!=0 for r in rows) else 2)
