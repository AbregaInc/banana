// Fresh synthetic requests from the actual public Banana extension registrations/sections.
import { build } from '../pi-host-proof/runtime/node_modules/esbuild/lib/main.js';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
const here=dirname(fileURLToPath(import.meta.url)), root=resolve(here,'../..');
const upstream=resolve(process.argv[2]??resolve(root,'../pi-upstream')),runtime=resolve(here,'../pi-host-proof/runtime');
const packages={'pi-ai':'ai','pi-telemetry':'telemetry','pi-durable':'durable',chord:'chord'};
const result=await build({stdin:{contents:readFileSync(resolve(runtime,'app.js'),'utf8')+`
globalThis.evaluationFixture = async active => {
 const read = { snapshot: async doc => doc.kind === NutritionDoc.kind && active ? {revision:2,surface:active} : null };
 const sections = [];
 for (const {section} of registry.snapshot().sections()) {
  const text = await section.render({read,conversationId:1},context);
  if(text) sections.push(section.tag === false ? text : '<'+section.key+'>\\n'+text+'\\n</'+section.key+'>');
 }
 return {instructions,sections,tools:registry.snapshot().tools().map(({tool})=>({name:tool.name,description:tool.description,parameters:tool.parameters}))};
};`,resolveDir:runtime},bundle:true,write:false,format:'iife',platform:'browser',conditions:['source'],nodePaths:[resolve(upstream,'node_modules')],plugins:[{name:'pinned-source',setup(b){
 b.onResolve({filter:/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/},({path})=>{const [,name,suffix]=path.match(/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/);const base=resolve(upstream,'packages',packages[name],'src',suffix?suffix.slice(1):'index');return {path:existsSync(base+'.ts')?base+'.ts':resolve(base,'index.ts')};});
 b.onResolve({filter:/^typebox$/},()=>({path:resolve(upstream,'node_modules/typebox/build/index.mjs')}));
}}]});
const meal='BA5A4E11-0000-4000-8000-000202610231';
const active={revision:2,metric:'protein',start:'2026-10-01',end:'2026-10-25',selectedDay:'2026-10-23',weekdaysOnly:false,compare:false,search:''};
const sandbox={nativeAgentConfiguration:'{}',console,TextEncoder,TextDecoder,URL,URLSearchParams,AbortController,setTimeout,clearTimeout,queueMicrotask,
 nativeToolCancel:()=>{},nativeToolStart:(raw,done)=>{const r=JSON.parse(raw);if(r.name!=='nutrition_view')throw Error('No capability executes in fixture generation');done(JSON.stringify({ok:true,value:{surface:r.arguments,summary:{loggedDays:1,loggedTotal:20,unit:'g',meals:[{id:meal,date:'2026-10-23',name:'Sample Greek yogurt breakfast'}]}}}));return 'fixture';}};
vm.runInNewContext(result.outputFiles[0].text,sandbox);
const clean=JSON.parse(JSON.stringify(await sandbox.evaluationFixture(null)));
const current=JSON.parse(JSON.stringify(await sandbox.evaluationFixture(active)));
const cases=[
 ['identity','What is your name?',null,{},false,{textIncludes:'banana'}],
 ['greeting','Hello',null,{},false],
 ['monthly','Show my protein this month','nutrition_view',{metric:'protein',period:'this_month'},false],
 ['calories','Show calories over the last seven days','nutrition_view',{metric:'calories',period:'last_7_days'},false],
 ['food-search','Find my logged meals containing yogurt','nutrition_view',{foodName:'yogurt'},true],
 ['weekdays','Only weekdays','filter_nutrition',{changes:['weekdays_only']},true],
 ['compare','Compare with the previous period','filter_nutrition',{changes:['compare_previous']},true],
 ['copy','Prepare a copy of the selected Greek yogurt breakfast for tomorrow, without saving.','prepare_meal_copy',{mealID:meal,day:'tomorrow'},true],
 ['new-meal','Log a new meal for today: 2 eggs and 1 banana. Prepare review, do not save.','prepare_meal',{},false,{foods:['egg','banana'],day:'today'}],
 ['new-event','Create an event called Lunch tomorrow at 13:00 for 30 minutes. Prepare review, do not save.','prepare_event',{title:'Lunch',time:'13:00',durationMinutes:30},false,{day:'tomorrow'}],
 ['explicit-event','Prepare a Dentist event on 2026-11-03 at 09:15 for 45 minutes.','prepare_event',{title:'Dentist',time:'09:15',durationMinutes:45},false,{day:'2026-11-03'}],
 ['missing-time','Create an event called Dinner. I have not decided the time.',null,{},false],
 ['missing-food','Log a meal. I have not said what I ate yet.',null,{},false],
 ['global-search','Search across Banana for clinic','search_app',{query:'clinic'},false],
 ['open-page','Open the Notes page','open_page',{section:'notes'},false],
 ['notes','Show my recent notes','list_notes',{},false],
 ['create-note','Create one note with this exact text: Bring the blue notebook','create_note',{text:'Bring the blue notebook'},false],
 ['plan','What is on my schedule today?','day_plan',{},false],
 ['unsupported','Delete every meal in my history',null,{},false],
 ['explanation','Explain what protein is. Use general knowledge, not my app data.',null,{},false],
 ['ambiguous','Do that other thing',null,{},false],
 ['not-a-write','For your information, I usually have eggs for breakfast. Do not log or save anything.',null,{},false],
];
const data={version:1,date:'2026-10-25',scope:'Development smoke corpus, not held-out or production accuracy. No capability executes. Prompt sections and schemas come from the real Banana extensions.',cases:cases.map(([id,text,tool,args,isActive,extra])=>{
 const f=isActive?current:clean;return {id,expected:{tool,arguments:args,...extra},request:{instructions:f.instructions+' The current device date is 2026-10-25.\n'+f.sections.join('\n'),tools:f.tools,messages:[{role:'user',text}]}};
})};
const canonical=JSON.stringify(data);data.sha256=createHash('sha256').update(canonical).digest('hex');
writeFileSync(resolve(here,'cases.json'),JSON.stringify(data,null,2)+'\n');
console.log(`Generated ${cases.length} synthetic cases with ${clean.tools.length} actual tools; ${data.sha256}`);
