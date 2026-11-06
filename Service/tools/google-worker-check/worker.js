// Exercises the real Workers Request constructor, without credentials or network calls.
import {createGoogle} from '../../src/google.js';
export default {async fetch() {
  const results = [];
  const operations = {
    calendar: google => google.calendarRead('fixture-token', {resource:'calendarList',query:[]}),
    mail: google => google.mailRead('fixture-token', {resource:'profile',query:[]}),
    draft: google => google.mailDraftSend('fixture-token', 'fixture-draft'),
  };
  for (const [name, operation] of Object.entries(operations)) {
    for (const redirect of [false, true]) {
      let calls = 0;
      const google = createGoogle({}, async (url, init) => {
        calls++;
        const request = new Request(url, init);
        if (request.redirect !== 'manual') throw new Error('redirect protection missing');
        return redirect ? new Response(null, {status:302,headers:{location:'https://untrusted.example/'}})
          : Response.json({items:[],id:'fixture-message',labelIds:['SENT'],emailAddress:'noor@plan.example'});
      });
      try {
        await operation(google);
        results.push({name,redirect,passed:!redirect && calls===1});
      } catch(error) {
        results.push({name,redirect,passed:redirect && calls===1 && error.name==='GoogleError'
          && error.message==='google redirect refused'});
      }
    }
  }
  const passed = results.every(result=>result.passed);
  return Response.json({passed,results},{status:passed?200:500});
}};
