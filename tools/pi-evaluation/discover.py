#!/usr/bin/env python3
"""Snapshot upstream candidate metadata. Read-only: never downloads weights or changes pins."""
import argparse,concurrent.futures,datetime,json,pathlib,urllib.request,urllib.error
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
here=pathlib.Path(__file__).resolve().parent;catalog=json.loads((here/'candidates.json').read_text())
def fetch(url):
 request=urllib.request.Request(url,headers={'User-Agent':'Banana-Pi-evaluation/1','Accept':'application/json'})
 with urllib.request.urlopen(request,timeout=30) as r:return json.load(r)
def engine(entry):
 result=dict(entry)
 try:
  url='https://api.github.com/repos/'+entry['repo'];r=fetch(url)
  commit=fetch(url+'/commits/'+r['default_branch'])
  result.update(url=r['html_url'],archived=r['archived'],license=(r.get('license')or{}).get('spdx_id'),branch=r['default_branch'],tip=commit['sha'],tipDate=commit['commit']['committer']['date'])
  try:
   release=fetch(url+'/releases/latest');result['latestRelease']={k:release.get(k) for k in ['tag_name','published_at','html_url']}
  except urllib.error.HTTPError as e:
   if e.code!=404:raise
   result['latestRelease']=None
 except Exception as e:result['error']=str(e)
 return result
def model(entry):
 result=dict(entry)
 try:
  r=fetch('https://huggingface.co/api/models/'+entry['repo']+'?blobs=true')
  result.update(url='https://huggingface.co/'+entry['repo'],revision=r['sha'],lastModified=r.get('lastModified'),gated=r.get('gated'),license=(r.get('cardData')or{}).get('license'),pipeline=r.get('pipeline_tag'),safetensors=r.get('safetensors'))
  result['baseModel']=(r.get('cardData')or{}).get('base_model')
  result['adapterOnly']=any(x['rfilename']=='adapter_config.json' for x in r.get('siblings',[]))
  result['assetBytesAreNotResidentMemory']=True
  result['weightFiles']=[{'file':x['rfilename'],'bytes':x.get('size'),'sha256':x.get('lfs',{}).get('sha256')} for x in r.get('siblings',[]) if x['rfilename'].endswith(('.safetensors','.gguf'))]
  result['downloadWeightBytes']=sum(x['bytes']or 0 for x in result['weightFiles'])
  result['weightBytesInterpretation']='Sum of repository weight assets, which can include alternative quantizations or draft/target assets. Select a concrete artifact; this is not required download size or resident RAM.'
 except Exception as e:result['error']=str(e)
 return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 engines=list(pool.map(engine,catalog['engines']));models=list(pool.map(model,catalog['models']))
fresh=[]
for author in catalog.get('discoveryAuthors',['Qwen','LiquidAI','google','mlx-community']):
 try:
  for item in fetch('https://huggingface.co/api/models?author='+author+'&sort=lastModified&direction=-1&limit=15'):
   if item.get('pipeline_tag') in ['text-generation','image-text-to-text']:
    fresh.append({k:item.get(k) for k in ['id','lastModified','pipeline_tag','downloads','gated']})
 except Exception as e:fresh.append({'author':author,'error':str(e)})
report={'freshModelSignals':fresh,'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Discovery only: tip/release metadata is not reviewed code, supported hardware proof or measured quality. No automatic promotion.', 'engines':engines,'models':models}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'engines':len(engines),'models':len(models),'errors':[x['repo'] for x in engines+models if x.get('error')]}))
