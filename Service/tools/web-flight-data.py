#!/usr/bin/env python3
"""Keep web flight deduplication's dictionaries tied to the native FlightParser and airport table."""
import json,pathlib,re,sys
root=pathlib.Path(__file__).resolve().parents[2]
s=(root/'Banana/Model/FlightParser.swift').read_text()
def array(name):
 body=re.search(r'let '+name+r'[^=]*=\s*\[(.*?)\n    \]',s,re.S).group(1)
 body=re.sub(r'//[^\n]*','',body)
 return re.findall(r'"([^"\n]*)"',body)
body=re.search(r'let mainAirport[^=]*=\s*\[(.*?)\n    \]',s,re.S).group(1)
airports={}
for line in (root/'Banana/Resources/Airports.tsv').read_text().splitlines():
 c=line.split('\t')
 if len(c)>=8:airports[c[0]]={'city':c[4],'size':c[6]}
data={n:array(n) for n in ['airlineWords','airlineCodes','months','weekdays','everydayCapitals']}
data['mainAirport']=dict(re.findall(r'"([^"\n]*)":\s*"([^"\n]*)"',body));data['airports']=airports
out=root/'Service/src/web/flight-data.json'
text=json.dumps(data,ensure_ascii=False,separators=(',',':'))+'\n'
if '--check' in sys.argv:
 if not out.exists() or out.read_text()!=text:sys.exit('Web flight dictionaries differ from the native app. Run tools/web-flight-data.py.')
else:out.write_text(text)
