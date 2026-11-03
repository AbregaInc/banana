// Replay recorded inference only when every consumed model request is unchanged.
// This tests deterministic host changes without pretending to be a new model run.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {routeGeneration} from '../pi-host-proof/runtime/capability-routing.js';
const [fixturePath,reportPath,baselinePath,outputPath,commandsPath]=process.argv.slice(2);
const hash=value=>createHash('sha256').update(value).digest('hex');
const fixture=JSON.parse(readFileSync(fixturePath)),old=JSON.parse(readFileSync(reportPath));
const baseline=readFileSync(baselinePath,'utf8');
const language=resolve('tools/pi-host-proof/runtime/request-language.js');
if(old.fixtureSha256!==hash(readFileSync(fixturePath)))throw Error('Fixture mismatch');
if(old.routingSha256!==hash(baseline))throw Error('Baseline routing source mismatch');
if(old.requestLanguageSha256!==hash(readFileSync(language)))throw Error('Baseline language helper changed');
let source=baseline.replace("'./request-language.js'",JSON.stringify(pathToFileURL(language).href));
if(commandsPath){
 const commands=readFileSync(commandsPath,'utf8');
 if(old.commandContractsSha256!==hash(commands))throw Error('Baseline commands mismatch');
 const imported=commands.replace("'./request-language.js'",JSON.stringify(pathToFileURL(language).href));
 source=source.replace("'./command-contracts.js'",JSON.stringify('data:text/javascript;base64,'+Buffer.from(imported).toString('base64')));
}
const {routeGeneration:original}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
const same=(a,b)=>JSON.stringify(canonical(a))===JSON.stringify(canonical(b));
const decode=raw=>{
 const m=raw.choices[0].message,content=[];
 if(m.content)content.push({type:'text',text:m.content});
 for(const t of m.tool_calls??[])content.push({type:'toolCall',id:t.id,name:t.function.name,arguments:JSON.parse(t.function.arguments)});
 return {content};
};
const encode=result=>{
 const calls=result.content.filter(p=>p.type==='toolCall');
 return {choices:[{finish_reason:calls.length?'tool_calls':'stop',message:{role:'assistant',content:result.content.filter(p=>p.type==='text').map(p=>p.text).join('\n'),...(calls.length?{tool_calls:calls.map(t=>({id:t.id,type:'function',function:{name:t.name,arguments:JSON.stringify(t.arguments)}}))}:{})}}]};
};
const cases=new Map(fixture.cases.map(c=>[c.id,c]));
const results=[];
for(const row of old.results){
 const c=cases.get(row.case),trace=row.raw.routingTrace??[],requests=[];let i=0;
 await original(c.request,async r=>{requests.push(structuredClone(r));if(!trace[i])throw Error('Missing baseline trace: '+c.id);return decode(trace[i++].response);});
 if(i!==trace.length)throw Error('Baseline did not consume recorded trace: '+c.id);
 i=0;let result,error;
 try{
  result=await routeGeneration(c.request,async r=>{
   if(!requests[i]||!same(r,requests[i]))throw Error('A model request changed; fresh inference required');
   return decode(trace[i++].response);
  });
 }catch(e){error=String(e);}
 results.push({case:c.id,repeat:0,replayed:true,consumedModelResponses:i,recordedModelResponses:trace.length,...(error?{error}:{raw:encode(result)})});
}
const report={complete:true,scope:'Recorded-response replay of deterministic host changes, NOT fresh model inference. Every consumed model request is compared with the hashed baseline policy before reusing its response. App tools do not execute.',fixtureSha256:old.fixtureSha256,baselineReport:reportPath,baselineRoutingSha256:old.routingSha256,routingSha256:hash(readFileSync('tools/pi-host-proof/runtime/capability-routing.js')),requestLanguageSha256:hash(readFileSync(language)),commandContractsSha256:hash(readFileSync('tools/pi-host-proof/runtime/command-contracts.js')),capabilityRouting:true,results};
writeFileSync(outputPath,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({queries:results.length,requireFreshInference:results.filter(r=>r.error).map(r=>r.case)},null,2));
