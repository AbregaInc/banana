// Evaluate the exact production routing function against an owned local worker.
import { routeGeneration } from '../pi-host-proof/runtime/capability-routing.js';
const canonical=value=>Array.isArray(value)?value.map(canonical):value && typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
let input='';for await(const chunk of process.stdin)input+=chunk;
const {request,payload,url}=JSON.parse(input), trace=[];
const generate=async native=>{
 const messages=[{role:'system',content:native.instructions},...native.messages.map(m=>({role:m.role,content:m.text}))];
 const body={...payload,messages,tools:native.tools.map(t=>({type:'function',function:t})),temperature:native.temperature??payload.temperature};
 const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(canonical(body)),signal:AbortSignal.timeout(120000)});
 if(!response.ok)throw Error(await response.text());
 const raw=await response.json();trace.push({tools:native.tools.map(t=>t.name),response:raw});
 const answer=raw.choices?.[0];
 if(!answer || !['stop','tool_calls'].includes(answer.finish_reason))throw Error('Incomplete model response');
 const content=[];if(answer.message.content)content.push({type:'text',text:answer.message.content});
 for(const t of answer.message.tool_calls??[])content.push({type:'toolCall',id:t.id,name:t.function.name,arguments:JSON.parse(t.function.arguments)});
 return {content};
};
const result=await routeGeneration(request,generate);
const tools=result.content.filter(p=>p.type==='toolCall');
console.log(JSON.stringify({choices:[{index:0,finish_reason:tools.length?'tool_calls':'stop',message:{role:'assistant',content:result.content.filter(p=>p.type==='text').map(p=>p.text).join('\n'),...(tools.length?{tool_calls:tools.map(t=>({id:t.id,type:'function',function:{name:t.name,arguments:JSON.stringify(t.arguments)}}))}:{})}}],routingTrace:trace}));
