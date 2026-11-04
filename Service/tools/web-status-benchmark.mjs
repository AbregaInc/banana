// Component ablation, synthetic in-memory spaces. No providers or production credentials.
import {DatabaseSync} from 'node:sqlite';
import {performance} from 'node:perf_hooks';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {sqlitePort} from '../src/adapters/spaces-sqlite.js';
import * as candidate from '../src/space.js';
const base=new URL('../src/space.js',import.meta.url);
const previous=execFileSync('git',['show','HEAD:Service/src/space.js'],{encoding:'utf8'}).replaceAll('"./calendar-preferences.js"',JSON.stringify(new URL('./calendar-preferences.js',base).href)).replaceAll('"./catalog.js"',JSON.stringify(new URL('./catalog.js',base).href));
const reference=await import('data:text/javascript;base64,'+Buffer.from(previous).toString('base64'));
const reports=[];
for(const count of [1,100,1000])for(const [name,implementation] of [['reference',reference],['candidate',candidate]]){
  const db=new DatabaseSync(':memory:'),raw=sqlitePort(db);let writes=0;
  const port={...raw,exec:(sql,...args)=>{if(/^(INSERT|UPDATE|DELETE)/.test(sql))writes++;return raw.exec(sql,...args);}};
  const now=1793707200000;
  const changes=Array.from({length:count},(_,i)=>({type:'notes.voiceNote',id:'n'+i,set:{transcript:'Synthetic note '+i},clocks:{transcript:now+'.0000.phone'}}));
  let head=0;const phases=[];
  for(const phase of ['cold','empty','same-values','edit','warm-empty']){
    writes=0;
    const batch=phase.includes('empty')?[]:changes.map(c=>({...c,set:phase==='edit'?{transcript:c.set.transcript+' edited'}:c.set,clocks:{transcript:now+'.'+(phase==='same-values'?'0001':phase==='edit'?'0002':'0000')+'.phone'}}));
    const start=performance.now();
    const result=implementation.sync(port,{device:'phone',platform:'iphone',since:head,changes:batch,now});
    const ms=performance.now()-start;head=result.answer.head;
    phases.push({phase,ms,writes,rejected:result.answer.rejected.length});
  }
  reports.push({name,count,phases});db.close();
}
console.log(JSON.stringify({reports,note:'Single-process component samples, not UI latency or a calibrated memory comparison. No new content cache; one revision metadata row is stored per space.'},null,2));
