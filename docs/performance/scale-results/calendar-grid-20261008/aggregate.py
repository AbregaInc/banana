import json, pathlib, math, sys
sys.path.insert(0, 'tools/calendar-library-benchmark')
from report import summarize
root=pathlib.Path(sys.argv[1])
result={}
for matrix in ['mac-pairs','mac-hosted-pairs','iphone-pairs','ipad-pairs']:
    folder=root/matrix
    if not (folder/'summary.json').exists(): continue
    groups={}
    for row in json.loads((folder/'summary.json').read_text()):
        path=folder/(row['scenario']+'.json')
        data=json.loads(path.read_text())
        computed=summarize(data)
        for key in ['status','acceptance','phases']:
            assert computed[key]==row[key],(path,key)
        key=f"{data['eventsPerDay']}/{data['optimizations']['ablation']}"
        group=groups.setdefault(key,{'runs':[],'samples':[]})
        samples=data['samples']+data['experiments']
        group['samples']+=samples
        group['runs'].append({'path':str(path.relative_to(root)),'phases':computed['phases'],
           'peakMiB':max(s['peakResidentBytes'] for s in samples)/2**20,
           'gridDrawCount':max(s.get('gridDrawCount',0) for s in samples),
           'gridDrawMS':max(s.get('gridDrawMS',0) for s in samples),
           'eventDrawMS':max(s.get('eventDrawMS',0) for s in samples)})
    for group in groups.values():
        samples=group.pop('samples'); group['phases']={}
        for phase in dict.fromkeys(s['phase'] for s in samples):
            v=sorted(s['milliseconds'] for s in samples if s['phase']==phase)
            group['phases'][phase]={'count':len(v),**{f'p{p}MS':v[math.ceil(len(v)*p/100)-1] for p in [50,95,99]},'maxMS':max(v),'over8_3MS':sum(x>8.3 for x in v),'over100MS':sum(x>100 for x in v)}
        group['peakMiBRange']=[min(r['peakMiB'] for r in group['runs']),max(r['peakMiB'] for r in group['runs'])]
    result[matrix]=groups
(root/'aggregate.json').write_text(json.dumps(result,indent=2)+'\n')
for matrix,groups in result.items():
    for name,g in groups.items():
        print(matrix,name,'scroll',round(g['phases']['scrollOffset']['p95MS'],2),round(g['phases']['scrollOffset']['maxMS'],2),'cold',round(g['phases']['coldMount']['maxMS'],2),'resize',round(g['phases']['resize']['maxMS'],2),'recovery',round(g['phases']['memoryPressurePage']['maxMS'],2),'RSS',*[round(x,1) for x in g['peakMiBRange']])
