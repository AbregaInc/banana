#!/usr/bin/env python3
"""Download a pinned public MLX checkpoint atomically, verifying Hub LFS hashes."""
import argparse,concurrent.futures,hashlib,json,pathlib,urllib.request,time
p=argparse.ArgumentParser();p.add_argument('repo');p.add_argument('revision');p.add_argument('directory',type=pathlib.Path);p.add_argument('--manifest',type=pathlib.Path,required=True);a=p.parse_args()
i=json.load(urllib.request.urlopen(f'https://huggingface.co/api/models/{a.repo}/revision/{a.revision}?blobs=true'))
assert i['sha']==a.revision
a.directory.mkdir(parents=True,exist_ok=True)
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def fetch(entry):
 name=entry['rfilename'];dest=a.directory/name
 if '/' in name or not(name.endswith(('.json','.jinja','.safetensors')) or name in ['README.md','LICENSE']):return None
 expected=entry.get('lfs',{}).get('sha256')
 if dest.exists() and dest.stat().st_size==entry['size'] and (not expected or digest(dest)==expected):pass
 else:
  print('Downloading',name,entry['size'],flush=True)
  temp=dest.with_suffix(dest.suffix+'.part')
  for attempt in range(3):
   try:
    with urllib.request.urlopen(f'https://huggingface.co/{a.repo}/resolve/{a.revision}/{name}',timeout=120) as r,temp.open('wb') as f:
     while chunk:=r.read(8*1024*1024):f.write(chunk)
    assert temp.stat().st_size==entry['size'],name+' size mismatch'
    if expected:assert digest(temp)==expected,name+' hash mismatch'
    temp.replace(dest);break
   except Exception:
    if attempt==2:raise
    time.sleep(2)
 actual=digest(dest);print('Verified',name,flush=True)
 return name,{'bytes':dest.stat().st_size,'sha256':actual}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 results=list(pool.map(fetch,i['siblings']))
manifest={'repo':a.repo,'revision':a.revision,'files':dict(r for r in results if r)}
a.manifest.write_text(json.dumps(manifest,indent=2)+'\n')
