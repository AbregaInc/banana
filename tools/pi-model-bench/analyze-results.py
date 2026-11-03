#!/usr/bin/env python3
"""Score captured intents against actual schemas and fixed-clock view semantics.
The on-device `correct` flag is only a strict expected-field check. This scorer
also accepts equivalent explicit dates and unchanged current view fields.
No response-text factual quality score or external action is implied.
"""
import argparse,json,pathlib,statistics
from jsonschema import Draft7Validator
p=argparse.ArgumentParser();p.add_argument('reports',type=pathlib.Path,nargs='+');a=p.parse_args()
fixtures=json.loads((pathlib.Path(__file__).parent/'requests.json').read_text())
cases={c['id']:c for c in fixtures['cases']}
periods={'this_month':('2026-10-01','2026-10-24'),'last_month':('2026-09-01','2026-09-30'),'last_7_days':('2026-10-18','2026-10-24'),'last_30_days':('2026-09-25','2026-10-24')}

def score(row):
 c=cases[row['case']];expect=c['expected'];response=row.get('response',{})
 content=response.get('content',[]);calls=[x for x in content if x.get('type')=='toolCall']
 if expect['tool'] is None:
  return not calls and any(x.get('text','').strip() for x in content),'no_tool'
 if len(calls)!=1 or calls[0].get('name')!=expect['tool']:return False,'wrong_tool'
 call=calls[0];args=call.get('arguments',{}).copy();name=call['name']
 if name in ['nutrition_view','filter_nutrition','prepare_meal_copy']:
  args['revision']=2 # Pi's task-bound hook replaces model-supplied metadata.
 schema=next(t['parameters'] for t in c['request']['tools'] if t['name']==name)
 if list(Draft7Validator(schema).iter_errors(args)):return False,'schema_invalid'
 expected=expect['arguments']
 if name=='nutrition_view':
  metric=args.get('metric','protein');start=args.get('start','2026-10-01');end=args.get('end','2026-10-24')
  if args.get('period'):
   if args['period'] not in periods:return False,'period_invalid'
   start,end=periods[args['period']]
  wanted_period=periods.get(expected.get('period','this_month'))
  if metric!=expected.get('metric','protein') or (start,end)!=wanted_period:return False,'wrong_view'
  if args.get('foodName','').strip().casefold()!=expected.get('foodName','').casefold():return False,'wrong_search'
 elif name=='filter_nutrition':
  if args.get('changes')!=expected['changes']:return False,'wrong_filters'
 elif name=='prepare_meal_copy':
  if args.get('mealID','').upper()!=expected['mealID'].upper():return False,'wrong_meal'
  if not (args.get('day')=='tomorrow' or (args.get('day')=='date' and args.get('date')=='2026-10-25')):return False,'wrong_day'
 elif name=='day_plan' and args.get('date') not in [None,'2026-10-24']:return False,'wrong_day'
 return True,'contract_pass'

summaries=[]
for path in a.reports:
 report=json.loads(path.read_text());rows=report['results']
 for row in rows:
  row['toolContractPass'],row['toolContractReason']=score(row)
 warm=[r['milliseconds'] for r in rows if r['repeat']>0]
 summary={'backend':report['backend'],'toolContractPasses':sum(r['toolContractPass'] for r in rows),'total':len(rows),'warmMedianMilliseconds':statistics.median(warm),'warmRangeMilliseconds':[min(warm),max(warm)],'scope':'Twelve synthetic independent fixed-clock requests, repeated. Tool/view contract checks only; conversational text quality not scored. Not production accuracy or p95.'}
 report['semanticContractSummary']=summary
 path.write_text(json.dumps(report,indent=2)+'\n')
 summaries.append(summary)
print(json.dumps(summaries,indent=2))
