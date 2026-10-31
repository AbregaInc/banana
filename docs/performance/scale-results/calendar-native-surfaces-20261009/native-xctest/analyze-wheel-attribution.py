import json,xml.etree.ElementTree as ET
from pathlib import Path
source=Path('.build/calendar-async-preparation/native-wheel-300-cpu.xml')
root=ET.parse(source).getroot();ids={e.get('id'):e for e in root.iter() if e.get('id')}
def resolved(e):
 while e.get('ref'):e=ids[e.get('ref')]
 return e
samples=[]
for row in root.iter('row'):
 cells=list(row)
 if len(cells)!=7:continue
 thread=resolved(cells[1])
 if 'Main Thread' not in thread.get('fmt',''):continue
 stack=resolved(cells[6]);names=[resolved(e).get('name','') for e in stack.iter('frame')]
 samples.append({'sampleTimeNS':int(resolved(cells[0]).text),'weightNS':int(resolved(cells[5]).text),
 'xctest':any('XCT' in n or 'XCElement' in n for n in names),
 'accessibility':any('Accessibility' in n or 'AXUIElement' in n for n in names),
 'nativeAccessibilityParent':any('NativeAccessibilityEvent.accessibilityParent' in n for n in names),
 'rasterRendering':any('RasterPage.render' in n for n in names)})
summary={'source':str(source),'scope':'Sampled main-thread stacks in a separate native wheel-only CPU trace; not latency or causal attribution of other traces','mainSamples':len(samples),'totalSampleWeightMS':sum(s['weightNS'] for s in samples)/1e6,'categories':{}}
for key in ['xctest','accessibility','nativeAccessibilityParent','rasterRendering']:
 selected=[s for s in samples if s[key]]
 summary['categories'][key]={'sampleCount':len(selected),'sampleWeightMS':sum(s['weightNS'] for s in selected)/1e6,'overlapWithXCTestSamples':sum(s['xctest'] for s in selected)}
summary['samples']=samples
out=Path('.build/calendar-async-preparation/native-wheel-attribution.json');out.write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if k!='samples'},indent=2))
