// Headless browser regression: synthetic data only. Set PLAYWRIGHT_MODULE to an installed package.
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import assert from 'node:assert/strict';
import {page as shell} from '../src/web/page.js';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const server=createServer(async(req,res)=>{
  try{const path=new URL(req.url,'http://localhost').pathname;
    if(path==='/app/'||/^\/share\/[A-Za-z0-9_-]{22}$/.test(path)){res.setHeader('Content-Type','text/html');res.end(shell());return;}
    if(!path.startsWith('/app/assets/')||path.includes('..')){res.writeHead(404).end();return;}
    const body=await readFile(path==='/app/assets/app.js'&&process.env.WEB_APP_SOURCE?process.env.WEB_APP_SOURCE:new URL('../public'+path,import.meta.url));res.setHeader('Content-Type',path.endsWith('.js')?'text/javascript':path.endsWith('.css')?'text/css':'image/svg+xml');res.end(body);
  }catch{res.writeHead(404).end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHANNEL?{channel:process.env.PLAYWRIGHT_CHANNEL}:{})});
try{
  const context=await browser.newContext({timezoneId:'America/New_York'}),page=await context.newPage();
  await page.clock.install({time:new Date('2026-11-04T17:00:00Z')});
  let account={email:'noor@plan.example',name:'Noor Haddad',consents:{health:true},counts:{'health.snapshot':1},lastSync:1,contentVersion:'initial',weekStartWeekday:2,preferences:{distanceUnit:'kilometers'}};
  const swift=s=>Date.parse(s)/1000-978307200;
  const payload={trends:{steps:[{date:swift('2026-11-02T05:00:00Z'),value:1000},{date:swift('2026-11-03T05:00:00Z'),value:2000}],sleepHours:[{date:swift('2026-11-03T05:00:00Z'),value:7}],nights:[{bedtime:swift('2026-11-03T04:50:00Z'),wake:swift('2026-11-03T12:00:00Z'),asleepMinutes:400,wakes:[{start:swift('2026-11-03T07:00:00Z'),end:swift('2026-11-03T07:10:00Z'),steps:20}]},{bedtime:swift('2026-11-02T05:10:00Z'),wake:swift('2026-11-02T12:30:00Z'),asleepMinutes:420,wakes:[]}]},workouts:[]};
  payload.trends.bodyMassKg=[{date:swift('2026-11-03T05:00:00Z'),value:76},{date:swift('2026-11-04T05:00:00Z'),value:75}];
  payload.trends.bodyFatPercentage=[{date:swift('2026-11-03T05:00:00Z'),value:.22},{date:swift('2026-11-04T05:00:00Z'),value:.21}];
  payload.trends.heightMeters=[{date:swift('2026-11-03T05:00:00Z'),value:1.75}];
  let calls=0;const forbiddenReads=[];
  await page.route('**/app/api/**',async route=>{
    const url=new URL(route.request().url());
    let body;
    if(url.pathname.endsWith('/account')||url.pathname.endsWith('/status')){calls++;body=account;}
    else if(url.pathname.endsWith('/blob'))body=payload;
    else if(url.pathname.endsWith('/calendars'))body={accounts:[]};
    else if(url.pathname.endsWith('/records')){const type=url.searchParams.get('type');if(account.shared&&!account.allowedTypes.includes(type))forbiddenReads.push(type);body={records:type==='health.snapshot'?[{id:'snapshot',fields:{v:{$blob:'a'.repeat(64)}}}]:type==='food.meal'?[{id:'meal',fields:{date:Date.parse('2026-11-03T13:00:00Z'),name:'Breakfast',items:[{name:'Yogurt',macros:{calories:200,proteinGrams:20,carbohydrateGrams:12,fatGrams:5}}]}}]:type==='food.supplement'?[{id:'sup',fields:{name:'Example supplement',dose:'1 tablet',ingredients:['Example ingredient']}}]:type==='food.dose'?[{id:'dose',fields:{supplementID:'sup',date:Date.parse('2026-11-03T13:00:00Z'),day:'20261103',status:'taken'}}]:[],next:null};}
    else throw new Error(url.pathname);
    await route.fulfill({json:body});
  });
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const origin=`http://127.0.0.1:${server.address().port}`;
  await page.goto(origin+'/app/#health');
  if(process.argv.includes('--refresh-only')){
    await page.waitForFunction(()=>document.querySelector('#content').getAttribute('aria-busy')==='false');
    await page.evaluate(()=>{window.mutations=0;new MutationObserver(a=>window.mutations+=a.length).observe(document.querySelector('#content'),{childList:true,subtree:true});});
    const samples=[];
    for(let i=0;i<5;i++){
      account={...account,lastSync:account.lastSync+1,contentVersion:'version-'+(account.lastSync+1)};const response=page.waitForResponse(r=>r.url().endsWith(process.env.WEB_APP_SOURCE?'/account':'/status'));const start=performance.now();
      await page.clock.fastForward(300_000);await response;await page.waitForFunction(()=>!document.querySelector('#refresh').disabled&&document.querySelector('#content').getAttribute('aria-busy')==='false');samples.push(performance.now()-start);
    }
    console.log(JSON.stringify({polls:5,contentMutations:await page.evaluate(()=>window.mutations),automationMS:samples,source:process.env.WEB_APP_SOURCE?'reference':'candidate',note:'DOM replacement comparison only; automation timings do not establish frame or input performance.'},null,2));
    await context.close();
  }else{
  await page.getByRole('button',{name:/Steps.*1,500/}).waitFor();
  const weight=page.locator('.metric-button').filter({hasText:'Weight'}),fat=page.locator('.metric-button').filter({hasText:'Body fat'});
  assert.match(await weight.innerText(),/90-day average/);
  assert.match(await weight.locator('.measure-value').innerText(),/76 kg/);
  assert.match(await weight.locator('.metric-latest').innerText(),/75 kg.*Nov 4/);
  assert.match(await fat.locator('.measure-value').innerText(),/22 %/);
  assert.match(await fat.locator('.metric-latest').innerText(),/21 %.*Nov 4/);
  assert.equal(await page.locator('.metric-button').filter({hasText:'Height'}).count(),0);
  await weight.click();await page.getByRole('dialog').getByRole('heading',{name:'Latest daily reading'}).waitFor();
  await page.getByRole('dialog').getByRole('button',{name:/Weight.*75 kg/}).click();await page.getByText('Daily value',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Close details'}).click();
  await page.getByRole('button',{name:/Steps.*1,500/}).click();
  await page.getByRole('dialog').getByRole('button',{name:/Steps.*1,000/}).click();
  await page.getByRole('dialog').getByRole('button',{name:/Steps.*1,000/}).click();
  await page.getByText('Daily value',{exact:true}).waitFor();
  // Timer polling must leave the dialog and exact content DOM untouched.
  await page.evaluate(()=>{window.originalContent=document.querySelector('#content').firstChild;window.originalDetail=document.querySelector('#detail-content').firstChild;window.mutations=0;new MutationObserver(a=>window.mutations+=a.length).observe(document.querySelector('#content'),{childList:true,subtree:true});});
  account={...account,lastSync:2,contentVersion:'changed'};
  const initialCalls=calls;
  for(let i=0;i<10;i++)await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
  assert.equal(calls,initialCalls);
  const before=calls;await page.clock.fastForward(300_000);
  await page.getByRole('button',{name:'Updates available. Refresh when ready'}).waitFor();
  assert.ok(calls>before);assert.equal(await page.locator('#detail').evaluate(d=>d.open),true);
  assert.equal(await page.evaluate(()=>window.originalContent===document.querySelector('#content').firstChild&&window.originalDetail===document.querySelector('#detail-content').firstChild),true);
  assert.equal(await page.evaluate(()=>window.mutations),0);
  // Access/consent invalidation must still remove an open private detail.
  account={...account,consents:{health:false}};await page.clock.fastForward(300_000);
  await page.getByRole('heading',{name:'Health sync is off'}).waitFor();assert.equal(await page.locator('#detail').evaluate(d=>d.open),false);
  account={...account,consents:{health:true}};await page.getByRole('button',{name:'Refresh',exact:true}).click();
  await page.getByRole('button',{name:/Steps.*1,500/}).waitFor();
  await page.getByText('Choose metrics',{exact:true}).click();await page.locator('[data-health-metric="steps"]').uncheck();
  await page.locator('[data-health-metric="steps"]:not(:checked)').waitFor();assert.equal(await page.locator('.metric-button').filter({hasText:'Steps'}).count(),0);
  await page.reload();await page.getByText('Choose metrics',{exact:true}).waitFor();assert.equal(await page.locator('[data-health-metric="steps"]').isChecked(),false);
  await page.getByText('Choose metrics',{exact:true}).click();await page.locator('[data-health-metric="steps"]').check();
  await page.locator('#content [data-trend-range]').selectOption('7');await page.getByRole('button',{name:/Steps.*1,500/}).waitFor();
  await page.getByRole('button',{name:/Sleep.*23:|Sleep.*11:50/}).first().click();
  await page.getByText('Sleep onset',{exact:true}).waitFor();await page.getByRole('button',{name:/Wake-up/}).click();await page.getByRole('heading',{name:'Recorded wake-up'}).waitFor();
  await page.getByRole('button',{name:'Close details'}).click();
  await page.locator('a[href="#nutrition"]').click();await page.getByText('Logged energy',{exact:true}).waitFor();await page.getByRole('button',{name:/Breakfast/}).click();await page.getByRole('heading',{name:'Breakfast'}).waitFor();
  await page.getByRole('button',{name:'Close details'}).click();
  await page.locator('a[href="#taken"]').click();await page.locator('#content .record').filter({hasText:'taken'}).click();
  await page.getByRole('heading',{name:'Example supplement'}).waitFor();await page.getByText('Counts for day',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Close details'}).click();await page.locator('a[href="#health"]').click();
  await page.setViewportSize({width:390,height:844});await page.getByRole('button',{name:/Steps.*1,500/}).waitFor();
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  // Repeated idle polls preserve the already-rendered content.
  const unchanged=await page.evaluate(()=>window.mutations);const times=[];
  for(let i=0;i<5;i++){const started=performance.now();account={...account,lastSync:account.lastSync+1,contentVersion:'version-'+(account.lastSync+1)};await page.clock.fastForward(300_000);await page.waitForFunction(()=>document.querySelector('#refresh').textContent.includes('Updates available'));times.push(performance.now()-started);}
  assert.equal(await page.evaluate(()=>window.mutations),unchanged);
  // A separate shared view has its own preferences and cannot request unshared logs.
  await page.getByText('Choose metrics',{exact:true}).click();await page.locator('[data-health-metric="steps"]').uncheck();
  await page.locator('[data-health-metric="steps"]:not(:checked)').waitFor();
  account={...account,shared:true,ownerName:'Noor Haddad',views:['overview','health'],allowedTypes:['health.snapshot'],shareVersion:1};
  await page.goto(origin+'/share/abcdefghijklmnopqrstuv#health');
  await page.getByRole('button',{name:/Steps.*1,500/}).waitFor();
  assert.equal(await page.locator('[data-health-metric="workoutLog"]').count(),0);
  if(process.env.WEB_SCREENSHOT)await page.screenshot({path:process.env.WEB_SCREENSHOT,fullPage:true});
  assert.deepEqual(forbiddenReads,[]);assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,checks:['day/week totals','daily detail','night and wake detail','metric persistence','zero background content mutations','open dialog preserved','consent withdrawal clears details','food detail','dose detail','mobile overflow','shared-view isolation'],pollAutomationMS:times,note:'Automation durations are not input-to-visible performance evidence.'},null,2));
  }
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
