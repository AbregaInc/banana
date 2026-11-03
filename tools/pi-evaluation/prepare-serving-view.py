#!/usr/bin/env python3
"""Public tokenizer metadata overrides in an isolated view; original weights/files stay unchanged."""
import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--model',required=True,type=pathlib.Path);p.add_argument('--manifest',required=True,type=pathlib.Path);p.add_argument('--directory',required=True,type=pathlib.Path);p.add_argument('--output-manifest',required=True,type=pathlib.Path);p.add_argument('--tool-parser',choices=['json_tools']);p.add_argument('--fix-mistral-regex',action='store_true');a=p.parse_args()
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while chunk:=f.read(8*1024*1024):h.update(chunk)
 return h.hexdigest()
source=a.model.resolve();dest=a.directory.resolve()
if source==dest or source in dest.parents or dest in source.parents:raise SystemExit('Serving view must be outside the original checkpoint directory')
if a.manifest.resolve()==a.output_manifest.resolve():raise SystemExit('Source and output manifests must differ')
m=json.loads(a.manifest.read_text());overrides={}
if a.tool_parser:overrides['tool_parser_type']=a.tool_parser
if a.fix_mistral_regex:overrides['fix_mistral_regex']=True
if not overrides:raise SystemExit('Specify an explicit supported tokenizer metadata override')
for name,entry in m['files'].items():
 f=source/name
 if pathlib.Path(name).name!=name or not f.is_file() or f.stat().st_size!=entry['bytes'] or sha(f)!=entry['sha256']:raise SystemExit('Source verification failed: '+name)
dest.mkdir(parents=True,exist_ok=True)
for name in m['files']:
 target=dest/name
 if name=='tokenizer_config.json':
  if target.is_symlink():raise SystemExit('Refusing to overwrite a tokenizer symlink')
  data=json.loads((source/name).read_text());data.update(overrides);temporary=target.with_suffix('.tmp');temporary.write_text(json.dumps(data,indent=2)+'\n');temporary.replace(target)
 elif target.is_symlink():
  if target.resolve()!=(source/name).resolve():raise SystemExit('Existing serving-view symlink points elsewhere: '+name)
 elif target.exists():raise SystemExit('Refusing to overwrite an existing non-symlink file: '+name)
 else:target.symlink_to(source/name)
result={k:v for k,v in m.items() if k!='files'};result.update(metadataOverrides=overrides,originalManifestSha256=sha(a.manifest),files={name:{'bytes':(dest/name).stat().st_size,'sha256':sha(dest/name)} for name in m['files']})
a.output_manifest.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'view':dest.name,'overrides':overrides,'originalFilesUnchanged':True}))
