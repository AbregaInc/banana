const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {createRequire}=require('node:module');
const args=process.argv.slice(2), deps=args[args.indexOf('--deps')+1], out=args[args.indexOf('--out')+1];
if(!args.includes('--deps')||!args.includes('--out')) throw Error('Usage: node tools/mail-readability/run.cjs --deps DEPENDENCY_DIRECTORY --out NEW_DIRECTORY');
fs.mkdirSync(out,{recursive:false});
const lib=createRequire(path.resolve(deps,'package.json'));
const {JSDOM,VirtualConsole}=lib('jsdom'),{Readability}=lib('@mozilla/readability');
const diagnostics=[]; const virtualConsole=new VirtualConsole();
virtualConsole.on('jsdomError',e=>diagnostics.push(e.message));
const root=process.cwd(), dir=path.join(root,'tools/reports/mail-cases');
const cases=fs.readdirSync(dir).filter(n=>fs.existsSync(path.join(dir,n,'input.html'))).map(n=>[n,fs.readFileSync(path.join(dir,n,'input.html'),'utf8')]);
cases.push(['short-action','<p>Your sign-in code is <strong>394821</strong>.</p><p><a href="https://account.example/secure">Secure account</a></p>']);
cases.push(['receipt','<h1>Receipt</h1><table><tr><th>Item</th><th>Amount</th></tr><tr><td>Notebook</td><td>$12.00</td></tr></table><p><a href="https://shop.example/refund">Request refund</a></p>']);
cases.push(['reply-chain','<p>Yes, Tuesday works.</p><blockquote><p>Could you confirm Tuesday?</p><p><a href="https://calendar.example/invite">View invitation</a></p></blockquote>']);
const links=doc=>[...doc.querySelectorAll('a[href]')].map(e=>e.href).filter(x=>/^https?:|^mailto:/.test(x));
let rows=[];
for(const [name,html] of cases){
  const original=new JSDOM(html,{url:'https://mail.example/',virtualConsole}); const expected=links(original.window.document);
  let result,ms=[];
  for(let i=0;i<10;i++){
    const dom=new JSDOM(html,{url:'https://mail.example/',virtualConsole});let t=performance.now();
    result=new Readability(dom.window.document,{maxElemsToParse:50000}).parse();ms.push(performance.now()-t);dom.window.close();
  }
  const output=new JSDOM(result?.content??'',{url:'https://mail.example/',virtualConsole});const kept=new Set(links(output.window.document));
  rows.push({name,sha256:crypto.createHash('sha256').update(html).digest('hex'),result:!!result,inputLinks:expected.length,missingLinks:[...new Set(expected)].filter(x=>!kept.has(x)),text:result?.textContent.trim().replace(/\s+/g,' '),parseMilliseconds:ms});
  original.window.close();output.window.close();
}
fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({readability:lib('@mozilla/readability/package.json').version,jsdom:lib('jsdom/package.json').version,node:process.version,options:{maxElemsToParse:50000},diagnostics,rows},null,2));
console.log(rows.map(r=>({name:r.name,result:r.result,inputLinks:r.inputLinks,missingLinks:r.missingLinks.length,parseMaxMs:Math.max(...r.parseMilliseconds).toFixed(1)})));
