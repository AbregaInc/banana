import test from 'node:test';
import assert from 'node:assert/strict';
import {createGoogle} from '../src/google.js';

const operations = {
  calendar: google => google.calendarRead('fixture-token', {resource:'calendarList',query:[]}),
  mail: google => google.mailRead('fixture-token', {resource:'profile',query:[]}),
  draft: google => google.mailDraftSend('fixture-token', 'fixture-draft'),
};
for (const [name, operation] of Object.entries(operations)) {
  test(`${name} rejects redirects without following or disclosing the redirect destination`, async () => {
    for (const status of [301,302,303,307,308]) {
      let calls = 0;
      const google = createGoogle({}, async (url, init) => {
        calls++;
        assert.equal(init.redirect, 'manual');
        assert.equal(init.headers.authorization, 'Bearer fixture-token');
        return new Response(null, {status, headers:{location:'https://untrusted.example/private'}});
      });
      await assert.rejects(operation(google), error => {
        assert.equal(error.name, 'GoogleError');
        assert.equal(error.status, 502);
        assert.equal(error.message, 'google redirect refused');
        return true;
      });
      assert.equal(calls, 1);
    }
  });
}
