// Build fixtures from Banana's actual registrations; never execute a capability.
import { build } from '../pi-host-proof/runtime/node_modules/esbuild/lib/main.js';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
const here = dirname(fileURLToPath(import.meta.url));
const upstream = resolve(process.argv[2]);
const runtime = resolve(here, '../pi-host-proof/runtime');
const packages = { 'pi-ai': 'ai', 'pi-telemetry': 'telemetry', 'pi-durable': 'durable', chord: 'chord' };
const result = await build({stdin: {contents: readFileSync(resolve(runtime,'app.js'),'utf8') + `\nglobalThis.fixture = { instructions, tools: registry.snapshot().tools().map(({tool}) => ({ name:tool.name, description:tool.description, parameters:tool.parameters })) };`, resolveDir:runtime}, bundle:true,write:false,format:'iife',platform:'browser',conditions:['source'],nodePaths:[resolve(upstream,'node_modules')],plugins:[{name:'pinned-source',setup(b){
 b.onResolve({filter:/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/},({path})=>{const [,name,suffix]=path.match(/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/);const base=resolve(upstream,'packages',packages[name],'src',suffix?suffix.slice(1):'index');return {path:existsSync(base+'.ts')?base+'.ts':resolve(base,'index.ts')};});
 b.onResolve({filter:/^typebox$/},()=>({path:resolve(upstream,'node_modules/typebox/build/index.mjs')}));
}}]});
const sandbox={nativeAgentConfiguration:'{}',console,TextEncoder,TextDecoder,URL,URLSearchParams,AbortController,setTimeout,clearTimeout,queueMicrotask};
vm.runInNewContext(result.outputFiles[0].text,sandbox);
const fixture = JSON.parse(JSON.stringify(sandbox.fixture));
const mealID='BA5A4E11-0000-4000-8000-000202610231';
const state='\n<nutrition-view>\nRevision 2\nCurrent native nutrition view: '+JSON.stringify({surface:{revision:2,metric:'protein',start:'2026-10-01',end:'2026-10-24',selectedDay:'2026-10-23',weekdaysOnly:false,compare:false,search:''},selectedMeals:[{id:mealID,name:'Sample · Greek yogurt breakfast',proteinGrams:20}]})+'. The host manages revision metadata. Successful view tools end the turn. prepare_meal_copy opens a draft and never saves.\n</nutrition-view>';
const cases=[
 ['monthly','Show my protein this month','nutrition_view',{metric:'protein',period:'this_month'}],
 ['calories','Show calories over the last seven days','nutrition_view',{metric:'calories',period:'last_7_days'}],
 ['search','Find my meals containing yogurt','nutrition_view',{foodName:'yogurt'}],
 ['weekdays','Only weekdays','filter_nutrition',{changes:['weekdays_only']}],
 ['compare','Compare with the previous period','filter_nutrition',{changes:['compare_previous']}],
 ['copy','Prepare a copy of the selected Greek yogurt breakfast for tomorrow. Do not save it yet.','prepare_meal_copy',{mealID,day:'tomorrow'}],
 ['notes','Show my recent notes','list_notes',{}],
 ['plan','What is on my schedule today?','day_plan',{}],
 ['greeting','Hello',null,{}],
 ['explanation','Explain what protein is',null,{}],
 ['unsupported','Delete every meal in my history',null,{}],
 ['ambiguous','Do that other thing',null,{}],
];
const data={version:1,description:'Synthetic fixed-clock action capture; no native capability execution. Exact registered tool schemas, synthetic active view, independent requests.',cases:cases.map(([id,text,tool,argumentsExpected])=>({id,expected:{tool,arguments:argumentsExpected},request:{instructions:fixture.instructions+' The current device date is 2026-10-24.'+state,tools:fixture.tools,messages:[{role:'user',text}],temperature:0,maxTokens:256}}))};
writeFileSync(resolve(here,'requests.json'),JSON.stringify(data,null,2)+'\n');
console.log(`Wrote ${data.cases.length} cases / ${fixture.tools.length} actual Banana tools`);
