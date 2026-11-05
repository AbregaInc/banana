import test from 'node:test';
import assert from 'node:assert/strict';
import {createGoogle} from '../src/google.js';

const request = {resource:'events',calendarID:'shared/calendar@plan.example',query:[]};
test('Calendar transport fixes the provider host and encodes IDs as individual path components',async()=>{
 let captured;
 const google=createGoogle({},async(url,init)=>{captured={url,init};return Response.json({items:[]});});
 await google.calendarRead('provider-access',request);
 const url=new URL(captured.url);
 assert.equal(url.origin,'https://www.googleapis.com');
 assert.equal(url.pathname,'/calendar/v3/calendars/shared%2Fcalendar%40plan.example/events');
 assert.equal(url.searchParams.get('maxResults'),'2500');
 assert.equal(captured.init.redirect,'error');
 assert.equal(captured.init.headers.authorization,'Bearer provider-access');
 assert.equal(url.searchParams.has('access_token'),false);
});

test('malformed provider success cannot masquerade as an empty calendar',async()=>{
 for(const response of [new Response('not JSON'),Response.json(null),Response.json([])]) {
  const google=createGoogle({},async()=>response);
  await assert.rejects(google.calendarRead('provider-access',request),{name:'GoogleError',status:502});
 }
});

test('provider error status and structured body survive the read transport',async()=>{
 const body={error:{code:410,message:'Sync token expired'}};
 const google=createGoogle({},async()=>Response.json(body,{status:410}));
 assert.deepEqual(await google.calendarRead('provider-access',request),{status:410,body});
});
