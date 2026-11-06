// Local workerd/D1 acceptance only; no Google requests or user data.
import {d1} from '../../src/adapters/d1.js';
import {reserveMailRead} from '../../src/mail-read-pacing.js';
import migration from '../../migrations/0021_mail_read_pacing.sql';
export default {async fetch(request,env) {
 await env.DB.prepare('CREATE TABLE IF NOT EXISTS google_links(sub TEXT PRIMARY KEY)').run();
 await env.DB.prepare(migration.replace('CREATE TABLE ','CREATE TABLE IF NOT EXISTS ')).run();
 await env.DB.prepare("INSERT OR IGNORE INTO google_links VALUES('fixture')").run();
 await env.DB.prepare('DELETE FROM mail_read_pacing').run();
 const deps={db:d1(env.DB),now:()=>10000};
 const results=await Promise.all(Array.from({length:12},()=>reserveMailRead(deps,'fixture',{resource:'thread',query:[]})));
 const waits=results.filter(Boolean).map(r=>r.waitMS).sort((a,b)=>a-b);
 const passed=JSON.stringify(waits)==='[0,1600,3200,4800,6400,8000,9600]'&&results.filter(r=>r===null).length===5;
 return Response.json({passed,waits,rejected:results.filter(r=>r===null).length},{status:passed?200:500});
}};
