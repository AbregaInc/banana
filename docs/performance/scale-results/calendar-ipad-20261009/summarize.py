import json,math
from pathlib import Path
root=Path('.build/calendar-ipad-20261009');output={}
def stats(values):
 values=sorted(values)
 return {'count':len(values),**{f'p{p}MS':values[math.ceil(len(values)*p/100)-1] for p in [50,95,99]},'maxMS':max(values)}
for matrix in ['foreground-surface','foreground-accessibility']:
 directory=root/matrix
 if not (directory/'summary.json').exists():continue
 rows=json.loads((directory/'summary.json').read_text());groups={}
 for row in rows:
  if row['status']!='measured':continue
  data=json.loads((directory/(row['scenario']+'.json')).read_text())
  name=str(data['eventsPerDay'])+'-'+data['optimizations']['ablation']
  group=groups.setdefault(name,{'cases':[],'foreground':[],'allSamples':[],'phases':{}})
  group['cases'].append(row['scenario']);group['foreground']+=data['foregroundExperiments']
  for field in ['samples','experiments','navigationExperiments','foregroundExperiments']:group['allSamples']+=data[field]
  for s in data['samples']+data['experiments']+data['navigationExperiments']:group['phases'].setdefault(s['phase'],[]).append(s['milliseconds'])
 result={}
 for name,g in groups.items():
  fg=g['foreground'];result[name]={'cases':g['cases'],'response':stats([s['responseMS'] for s in fg]),'mainSection':stats([s['maxMainSectionMS'] for s in fg]),'peakResidentBytes':max(s['peakResidentBytes'] for s in g['allSamples']),'maxSampledPhysicalFootprintBytes':max(s['physicalFootprintBytes'] for s in g['allSamples']),'originalPhases':{k:stats(v) for k,v in g['phases'].items()},'foregroundPhases':{phase:{key:stats([s[key] for s in fg if s['phase']==phase]) for key in ['responseMS','maxMainSectionMS']} for phase in sorted({s['phase'] for s in fg})}}
 output[matrix]={'caseStatuses':{r['scenario']:r['status'] for r in rows},'groups':result}
(root/'pooled.json').write_text(json.dumps(output,indent=2)+'\n')
for matrix,data in output.items():
 print(matrix)
 for name,g in data['groups'].items():print(name,len(g['cases']),'response',round(g['response']['maxMS'],3),'main',round(g['mainSection']['maxMS'],3),'rssMiB',round(g['peakResidentBytes']/1048576,2),'footprintMiB',round(g['maxSampledPhysicalFootprintBytes']/1048576,2))
