#!/usr/bin/env python3
"""Inspect pinned tokenizers/parsers without loading weights or executing tools."""
import argparse,json,pathlib
from mlx_lm.utils import load_tokenizer
from locals.formats import detect_from_template,chat_template
p=argparse.ArgumentParser();p.add_argument('models',nargs='+',type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
rows=[]
for model in a.models:
 t=load_tokenizer(model)
 row={'modelDirectory':model.name,'mlxToolCalling':t.has_tool_calling,'mlxToolParser':t.tool_parser.__module__ if t.has_tool_calling else None,'localsFormat':detect_from_template(chat_template(t)).name}
 cfg=json.loads((model/'tokenizer_config.json').read_text())
 row['explicitMetadata']={k:cfg[k] for k in ['tool_parser_type','fix_mistral_regex'] if k in cfg}
 probe={'name':'banana_qualification_probe','description':'Tokenizer rendering probe only; never executed.','parameters':{'type':'object','properties':{'value':{'type':'integer'}},'required':['value']}}
 for key,extra in [('standardToolNameRendered',{}),('xmlToolNameRendered',{'xml_tools':[probe]})]:
  rendered=t.apply_chat_template([{'role':'system','content':'You are Banana.'},{'role':'user','content':'Hello'}],tools=[{'type':'function','function':probe}],enable_thinking=False,tokenize=False,add_generation_prompt=True,**extra)
  row[key]=probe['name'] in rendered
 rows.append(row)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows))
