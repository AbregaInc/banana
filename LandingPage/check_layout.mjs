// Headless layout/navigation checks; no desktop windows or native app/device work.
import { chromium } from 'playwright-core';
import { mkdirSync,writeFileSync } from 'node:fs';
const base=process.argv[2] || 'http://127.0.0.1:8897';
const out=new URL(process.argv[3] || '../docs/blog/calendar-renderer/evidence/',import.meta.url);
mkdirSync(out,{recursive:true});
const browser=await chromium.launch({channel:'chromium-headless-shell'});
const results=[];
try{
 for(const width of [375,768,1440]){
  const context=await browser.newContext({viewport:{width,height:1000},reducedMotion:'reduce'});
  for(const path of ['/','/blog/','/blog/building-a-measurable-calendar-renderer/','/about','/support','/privacy','/terms']){
   const page=await context.newPage(); const errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   const response=await page.goto(base+path,{waitUntil:'networkidle'});
   await page.evaluate(()=>document.fonts.ready);
   const check=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,h1:document.querySelectorAll('h1').length,main:document.querySelectorAll('main').length,images:[...document.images].filter(i=>!i.complete||!i.naturalWidth).map(i=>i.src),navVisible:[...document.querySelectorAll('header nav a')].filter(a=>a.getClientRects().length).map(a=>a.textContent)}));
   const passed=response.status()===200&&check.scrollWidth<=width&&check.h1===1&&check.main===1&&!check.images.length&&!errors.length;
   results.push({width,path,status:response.status(),passed,...check,errors});
   if(['/blog/','/blog/building-a-measurable-calendar-renderer/'].includes(path)&&(width===375||width===1440))await page.screenshot({path:new URL(`blog${path==='/blog/'?'-index':'-article'}-${width}.png`,out).pathname,fullPage:true});
   if(path==='/blog/'){
    await page.getByRole('heading',{name:'Building a calendar renderer we can measure'}).getByRole('link').click();
    if(!page.url().endsWith('/blog/building-a-measurable-calendar-renderer/'))throw new Error('Blog article navigation failed');
   }
   await page.close();
  }
  await context.close();
 }
 const context=await browser.newContext({javaScriptEnabled:false,viewport:{width:375,height:900}});
 const page=await context.newPage();await page.goto(base+'/blog/building-a-measurable-calendar-renderer/');
 results.push({case:'no-javascript',passed:await page.getByRole('heading',{name:'What the native Week comparison showed'}).isVisible()});await context.close();
 writeFileSync(new URL('layout.json',out),JSON.stringify(results,null,2)+'\n');
 console.log(JSON.stringify({checks:results.length,failures:results.filter(r=>!r.passed)},null,2));
 if(results.some(r=>!r.passed))process.exitCode=1;
}finally{await browser.close()}
