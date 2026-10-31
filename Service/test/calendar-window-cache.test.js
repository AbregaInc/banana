import test from 'node:test';
import assert from 'node:assert/strict';
import {CalendarWindowCache} from '../public/app/assets/calendar-window-cache.js';
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
test('calendar windows: concurrent sentences share one read, including an empty result',async()=>{
 const gate=deferred(),cache=new CalendarWindowCache();let calls=0;
 const load=()=>{calls++;return gate.promise;};
 const reads=[cache.read('today',load),cache.read('today',load),cache.read('today',load)];
 await Promise.resolve();assert.equal(calls,1);gate.resolve({events:[]});
 const rows=await Promise.all(reads);assert.equal(rows[0],rows[1]);assert.equal(rows[1],rows[2]);
 await cache.read('today',load);assert.equal(calls,1);
 cache.clear();await cache.read('today',load);assert.equal(calls,2);
});
test('calendar windows: rejection and evicted work cannot erase a newer read',async()=>{
 const cache=new CalendarWindowCache(1),gate=deferred();
 const old=cache.read('today',()=>gate.promise.then(()=>{throw Error('old failed');}));
 await cache.read('week',()=>({events:[1]}));
 const newer=await cache.read('today',()=>({events:[2]}));
 gate.resolve();await assert.rejects(old,/old failed/);
 assert.equal(await cache.read('today',()=>{throw Error('should be cached');}),newer);
 cache.clear();await assert.rejects(cache.read('today',()=>{throw Error('retryable');}),/retryable/);
 assert.deepEqual(await cache.read('today',()=>({events:[3]})),{events:[3]});
});
test('calendar windows: bounded eviction and controlled pending-read ablation',async()=>{
 const cache=new CalendarWindowCache(2);let loads=0;
 for(const key of ['one','two','three','one'])await cache.read(key,()=>++loads);
 assert.equal(loads,4);
 const old=new Map(),gate=deferred();let referenceCalls=0,sharedCalls=0;
 async function reference(){if(!old.has('k'))old.set('k',await (()=>{referenceCalls++;return gate.promise;})());return old.get('k');}
 const ref=[reference(),reference(),reference()],shared=new CalendarWindowCache();
 const next=[0,1,2].map(()=>shared.read('k',()=>{sharedCalls++;return gate.promise;}));
 await Promise.resolve();gate.resolve('same data');
 assert.deepEqual(await Promise.all(ref),await Promise.all(next));
 assert.equal(referenceCalls,3);assert.equal(sharedCalls,1);
});

test('calendar windows: obsolete fetch signals abort on refresh and eviction',async()=>{
 const cache=new CalendarWindowCache(1);let first,second;
 await cache.read('one',signal=>{first=signal;return 1;});
 await cache.read('two',signal=>{second=signal;return 2;});
 assert.equal(first.aborted,true);assert.equal(second.aborted,false);
 cache.clear();assert.equal(second.aborted,true);
});
