#!/usr/bin/env python3
"""Record public HTTP/crawler evidence without credentials or account dashboards."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from check_seo import Document

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None

parser=argparse.ArgumentParser()
parser.add_argument('--origin', default='https://bananatheapp.com')
parser.add_argument('--out', type=Path, required=True)
args=parser.parse_args()
paths=['/','/privacy','/terms','/support','/about','/blog/','/blog/building-a-measurable-calendar-renderer/','/blog/how-busy-blocks-work/','/blog/feed.xml','/sitemap.xml','/robots.txt','/seo-audit-missing-page','/blog','/index.html','/privacy.html']
requests=[(args.origin+path,'Banana-site-audit/1.0') for path in paths]
if args.origin=='https://bananatheapp.com':
    requests += [('https://www.bananatheapp.com'+path,'Banana-site-audit/1.0') for path in ['/','/blog/']]
    requests += [('http://bananatheapp.com/','Banana-site-audit/1.0')]
requests += [(args.origin+'/',ua) for ua in ['Googlebot','bingbot','OAI-SearchBot','Claude-SearchBot']]
results=[]
opener=build_opener(NoRedirect)
for url,ua in requests:
    try:
        try: response=opener.open(Request(url, headers={'User-Agent':ua}),timeout=30)
        except HTTPError as error: response=error
        body=response.read()
        record={'url':url,'userAgent':ua,'status':response.status,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest(),'headers':{k.lower():v for k,v in response.headers.items() if k.lower() in ['content-type','cache-control','location','x-robots-tag','content-encoding','x-content-type-options','vary']}}
        if 'text/html' in response.headers.get('Content-Type',''):
            # Provider-injected analytics is not part of our static content. Preserve the
            # raw digest and flag it; normalize only this known script for parity checks.
            normalized = re.sub(rb'<script\b[^>]*src="https://static\.cloudflareinsights\.com/beacon\.min\.js/[^" ]+"[^>]*></script>\n?', b'', body)
            record['cloudflareBeaconInjected'] = normalized != body
            record['staticContentSha256'] = hashlib.sha256(normalized).hexdigest()
            page=Document();page.feed(body.decode('utf-8'));record.update(title=page.title,canonical=page.canonical,robots=page.meta.get('robots'),h1s=page.h1s,structuredData=len(page.schemas),description=page.meta.get('description'))
        if url.endswith('/robots.txt'):record['body']=body.decode()
        results.append(record)
    except Exception as error:results.append({'url':url,'userAgent':ua,'error':str(error)})
args.out.parent.mkdir(parents=True,exist_ok=True)
args.out.write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps([{'url':r['url'],'ua':r['userAgent'],'status':r.get('status'),'location':r.get('headers',{}).get('location'),'error':r.get('error')} for r in results],indent=2))
