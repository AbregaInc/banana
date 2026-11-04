#!/usr/bin/env python3
"""Review routing contracts without relabeling capability gaps as implemented features."""
import argparse,collections,hashlib,json,pathlib
from common_contracts import score_common
p=argparse.ArgumentParser();p.add_argument('report',type=pathlib.Path);p.add_argument('--fixture',type=pathlib.Path,default=pathlib.Path(__file__).with_name('common-queries-v1.json'));p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
fixture=json.loads(a.fixture.read_text());raw=json.loads(a.report.read_text());cases={c['id']:c for c in fixture['cases']}
assert raw['fixtureSha256']==hashlib.sha256(a.fixture.read_bytes()).hexdigest(),'Fixture changed; do not score different prompts against this run'
correction_path=pathlib.Path(__file__).with_name('common-oracle-corrections.json')
corrections=json.loads(correction_path.read_text()) if correction_path.exists() else {'cases':{}}
for case_id, patch in corrections['cases'].items():
    if case_id in cases: cases[case_id].update(patch)
modules=collections.defaultdict(collections.Counter);failures=[];review=[];verdicts={} 
for row in raw['results']:
    case=cases[row['case']];passed,reason=score_common(case,row.get('raw',{}));verdicts[case['id']]=(passed,reason)
    count=modules[case['module']];count['tested']+=1
    if case['capability']=='capability_gap':count['capability_gap_cases']+=1
    if not passed:
        count['contract_failures']+=1
        failures.append({'id':case['id'],'query':case['request']['messages'][0]['text'],'capability':case['capability'],'reason':reason,'response':row.get('raw',{}).get('choices',[])})
    elif reason=='reply_needs_semantic_review':
        count['text_requires_review']+=1
        review.append({'id':case['id'],'query':case['request']['messages'][0]['text'],'capability':case['capability'],'response':row['raw']['choices'][0]['message'].get('content','')})
    elif case['capability']=='capability_gap':count['navigation_fallbacks']+=1
    else:count['tool_contract_passes']+=1
summary={'complete':raw['complete'],'queries':len(raw['results']),'scope':fixture['scope'],'evidenceScope':raw.get('scope'),'evidenceCounts':raw.get('evidenceCounts'),
 'scorerSha256':hashlib.sha256(pathlib.Path(__file__).with_name('common_contracts.py').read_bytes()).hexdigest(),
 'fixtureSha256':raw['fixtureSha256'],'capabilityRouting':raw.get('capabilityRouting',False),'routingSha256':raw.get('routingSha256'),'routingDriverSha256':raw.get('routingDriverSha256'),'requestLanguageSha256':raw.get('requestLanguageSha256'),'commandContractsSha256':raw.get('commandContractsSha256'),'oracleCorrections':corrections,'modules':dict(modules),'failures':failures,'textReviewQueue':review}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(summary,indent=2)+'\n')
lines=['# Common-query evaluation','',fixture['scope'],'',raw.get('scope',''),'','Evidence counts: '+json.dumps(raw.get('evidenceCounts',{})), '',f"This run evaluated {len(raw['results'])} queries. Documented oracle corrections are applied without changing the raw responses; see the JSON report.",'',
'Automatic checks verify routing, arguments, schema, missing-input behavior, and some false completion claims. Text replies below still require semantic review. A navigation fallback does not implement the requested capability. No app tools execute in this benchmark; native/full-app tests are separate.','',
'| Module | Tested | Tool contracts passed | Honest navigation fallback | Text to review | Contract failures | Capability-gap cases |',
'|---|---:|---:|---:|---:|---:|---:|']
for module,c in modules.items(): lines.append('| '+module+' | '+' | '.join(str(c[k]) for k in ['tested','tool_contract_passes','navigation_fallbacks','text_requires_review','contract_failures','capability_gap_cases'])+' |')
lines+=['','## Failures','']
for f in failures:
    response=f['response'][0]['message'] if f['response'] else {}
    lines+=['### '+f['id'],'','Query: '+f['query'],'','Contract failure: `'+f['reason']+'` ('+f['capability']+').','','```json',json.dumps(response,ensure_ascii=False,indent=2),'```','']
a.output.with_suffix('.md').write_text('\n'.join(lines)+'\n')
catalog=['# 900 common-query development cases','','Twenty intent families × five variants per module. Synthetic, not ranked by actual usage.','']
for module in fixture['moduleCounts']:
    catalog+=['## '+module.title(),'','| Query | Capability | Result |','|---|---|---|']
    for c in cases.values():
        if c['module']!=module:continue
        verdict=verdicts.get(c['id']);status=verdict[1] if verdict else 'not run'
        catalog.append('| '+c['request']['messages'][0]['text'].replace('|','\\|')+' | '+c['capability']+' | '+status+' |')
(a.output.parent/(a.output.stem+'-catalog.md')).write_text('\n'.join(catalog)+'\n')
print(json.dumps({'complete':summary['complete'],'queries':summary['queries'],'modules':dict(modules)},indent=2))
