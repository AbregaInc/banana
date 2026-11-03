#!/usr/bin/env python3
"""Measure the original Kev-0.5B decision head, with unchanged v0.1.0 model.py.
This measures routing only, not slot extraction or complete Banana actions.
Pass a prepared kev05-probe directory and a pinned local Qwen base directory.
"""
import argparse,hashlib,importlib.util,importlib.metadata,json,pathlib,platform,time
parser=argparse.ArgumentParser()
parser.add_argument('probe',type=pathlib.Path)
parser.add_argument('base',type=pathlib.Path)
parser.add_argument('--output',type=pathlib.Path,required=True)
a=parser.parse_args()
import torch
from peft import PeftModel
release_digest='15639f791361258432fc954a68023bca95260dade61f731b4260eb60f06e12f8'
assert hashlib.sha256((a.probe/'kev-0.5b.tar.gz').read_bytes()).hexdigest()==release_digest, 'Unexpected Kev release'
assert hashlib.sha256((a.probe/'model.py').read_bytes()).hexdigest()=='f11fba2114a354c99cfd4378599b6116131909c1d154f8543ec4050d6681a7e7', 'Expected unchanged Kev v0.1.0 model.py'
spec=importlib.util.spec_from_file_location('kev05_original',a.probe/'model.py')
original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
checkpoint=a.probe/'kev-0.5b'
meta=torch.load(checkpoint/'head.pt',map_location='cpu',weights_only=True)
start=time.perf_counter()
tok=original.load_tokenizer(str(checkpoint))
device='mps' if torch.backends.mps.is_available() else 'cpu'
model=original.DecisionModel(str(a.base),tok,device,lora=None)
model.lm=PeftModel.from_pretrained(model.lm,checkpoint).to(device)
model.head.load_state_dict(meta['head']);model.eval()
load_ms=(time.perf_counter()-start)*1000
fixture=json.loads((pathlib.Path(__file__).parent/'requests.json').read_text())
options={c['name']:c['description'] for c in fixture['cases'][0]['request']['tools']}
options['no_tool']='Reply conversationally, explain, ask for clarification, or explain unsupported actions. No Banana app action fits.'
keys=list(options)
T=json.loads((checkpoint/'eval.json').read_text())['temperature_scaling']['T']
rows=[]
for repeat in range(3):
 for case in fixture['cases']:
  text=case['request']['messages'][0]['text']
  state=json.dumps({'user_request':text,'current_view':{'type':'nutrition_chart','metric':'protein','selected_meal':'Greek yogurt breakfast','selected_day':'2026-10-23'},'current_date':'2026-10-24'})
  rec={'state':state,'questions':[{'instr':'Which one Banana action best answers this user request? Select no_tool if no listed action is appropriate.','options':[f'{k}: {v}' for k,v in options.items()],'label':0}]}
  enc=original.encode(tok,rec,max_state=2048,max_branch=4096)
  if device=='mps':torch.mps.synchronize()
  t=time.perf_counter()
  with torch.inference_mode():
   p=(model(enc)[0]/T).softmax(-1).cpu().tolist()
  if device=='mps':torch.mps.synchronize()
  ms=(time.perf_counter()-t)*1000
  best=max(range(len(p)),key=p.__getitem__)
  prediction=keys[best];expected=case['expected']['tool'] or 'no_tool'
  row={'case':case['id'],'repeat':repeat,'milliseconds':round(ms,1),'prediction':prediction,'expected':expected,'correct':prediction==expected,'probabilities':dict(zip(keys,p)),'inputTokens':len(enc['ids'])}
  rows.append(row)
  print(json.dumps({k:v for k,v in row.items() if k!='probabilities'}),flush=True)
report={'model':'kev-0.5b','release':'v0.1.0','sourceCommit':'ac67bf4e52d7bdc8420d8024c396df5585915d8c','sourceSHA256':hashlib.sha256((a.probe/'model.py').read_bytes()).hexdigest(),'checkpointSHA256':release_digest,'packages':{p:importlib.metadata.version(p) for p in ['torch','transformers','peft','tokenizers']},'device':device,'machine':platform.machine(),'chip':__import__('subprocess').check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'host':platform.mac_ver()[0],'temperature':T,'loadMilliseconds':load_ms,'scope':'Synthetic tool routing only; no argument generation, app execution, or mobile measurement. Tokenization excluded from forward timings.','results':rows}
a.output.write_text(json.dumps(report,indent=2)+'\n')
