// node --test tools/pi-host-proof/runtime/mail-reply.test.mjs
// Bundles mail-entry.js against the reviewed upstream Pi checkout (PI_UPSTREAM, default ../pi-upstream next to
// the repository) and drives the banana-mail extension with a scripted model at the native boundary.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

const directory = dirname(fileURLToPath(import.meta.url));
const upstream = resolve(process.env.PI_UPSTREAM ?? resolve(directory, '../../../../pi-upstream'));
const available = existsSync(resolve(upstream, 'packages/durable/src/index.ts'));
let runtime;
async function load() {
  if (runtime) return runtime;
  const packages = { 'pi-ai': 'ai', 'pi-telemetry': 'telemetry', 'pi-durable': 'durable', chord: 'chord' };
  const plugin = { name: 'upstream-source', setup(b) {
    b.onResolve({ filter: /^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/ }, ({ path }) => {
      const [, name, suffix] = path.match(/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/);
      const base = resolve(upstream, 'packages', packages[name], 'src', suffix ? suffix.slice(1) : 'index');
      return { path: existsSync(base + '.ts') ? base + '.ts' : resolve(base, 'index.ts') };
    });
    b.onResolve({ filter: /^typebox$/ }, () => ({ path: resolve(upstream, 'node_modules/typebox/build/index.mjs') }));
  } };
  const outfile = resolve(mkdtempSync(resolve(tmpdir(), 'pi-mail-')), 'mail.mjs');
  await build({ entryPoints: [resolve(directory, 'mail-entry.js')], outfile, bundle: true, platform: 'node', format: 'esm',
    conditions: ['source'], plugins: [plugin], nodePaths: [resolve(upstream, 'node_modules')], logLevel: 'silent',
    banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" } });
  runtime = await import(pathToFileURL(outfile).href);
  return runtime;
}

const email = { subject: 'Room', from: 'colleague@plan.example', account: 'noor@plan.example', to: ['colleague@plan.example'], cc: [],
  email: 'Can you confirm the room is Oak?' };
const call = (name, args, id) => ({ content: [{ type: 'toolCall', id, name, arguments: args }] });

// A scripted model: each step returns the next answer; requests are recorded.
function scripted(steps) {
  const requests = [];
  let index = 0;
  const generate = async (request) => {
    requests.push(request);
    const step = steps[Math.min(index++, steps.length - 1)];
    return typeof step === 'function' ? step(request, index) : step;
  };
  return { generate, requests };
}
function natives(handlers = {}) {
  const calls = [];
  const native = async (name, args) => {
    calls.push({ name, args });
    if (handlers[name]) return handlers[name](args);
    if (name === 'check_reply') return { ok: true };
    if (name === 'check_picker') return { ok: true, picker: { reply: 'needed', questions: args.questions } };
    return { records: [{ kind: 'selectedMessage', from: 'owner', subject: 'Room', text: 'Earlier note.' }] };
  };
  return { native, calls };
}

test('a checked reply becomes the body; required tool choice and reasoning budget reach the native model', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('read_thread', {}, 'r1'), call('submit_reply', { body: ' Yes, it is Oak. ' }, 's1')]);
  const tools = natives();
  const result = await runMailReply({ task: 'Write my reply.', email, provider: 'mac-local', modelId: 'test-model', thinking: 'low', reasoningBudget: 1024 },
    { native: tools.native, generate: model.generate });
  assert.deepEqual(result, { body: 'Yes, it is Oak.' });
  assert.deepEqual(tools.calls.map(c => c.name), ['read_thread', 'check_reply']);
  for (const request of model.requests) {
    assert.equal(request.toolChoice, 'required');
    assert.equal(request.reasoningBudget, 1024);
    assert.equal(request.backend, 'mac-local');
    assert.equal(request.reasoning, 'low');
  }
  assert.deepEqual(model.requests[0].tools.map(t => t.name).sort(), ['ask_owner', 'check_time', 'find_free_time', 'no_reply_needed', 'read_attachments', 'read_thread', 'search_mail', 'submit_reply']);
});

test('Apple requests carry no reasoning or backend', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('submit_reply', { body: 'Yes.' }, 's1')]);
  const result = await runMailReply({ email }, { native: natives().native, generate: model.generate });
  assert.deepEqual(result, { body: 'Yes.' });
  assert.equal(model.requests[0].backend, undefined);
  assert.equal(model.requests[0].reasoning, undefined);
  assert.equal(model.requests[0].toolChoice, 'required');
});

test('a rejected reply returns the problem to the model, which may then ask the owner', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('submit_reply', { body: 'It costs $40.' }, 's1'), (request) => {
    const last = request.messages.at(-1);
    assert.equal(last.role, 'toolResult');
    assert.match(last.text, /"accepted":false/);
    return call('ask_owner', { questions: [{ question: 'Is the room Oak?', control: 'yes_no', options: [], quote: 'Can you confirm the room is Oak?' }] }, 'a1');
  }]);
  const tools = natives({ check_reply: () => ({ ok: false, problem: 'Unsupported amount.' }) });
  const result = await runMailReply({ email }, { native: tools.native, generate: model.generate });
  assert.equal(result.reply, 'needed');
  assert.deepEqual(result.questions.map(q => q.control), ['yes_no']);
});

test('no_reply_needed maps to noReply with the reason', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('no_reply_needed', { reason: 'A shipping notice.' }, 'n1')]);
  assert.deepEqual(await runMailReply({ email }, { native: natives().native, generate: model.generate }), { noReply: true, reason: 'A shipping notice.' });
});

test('a picker with no grounded question is refused and the model must try again', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('ask_owner', { questions: [{ question: 'What?', control: 'text', options: [], quote: 'not in mail' }] }, 'a1'),
    call('submit_reply', { body: 'Yes.' }, 's1')]);
  const tools = natives({ check_picker: () => ({ ok: true, picker: { reply: 'needed', questions: [] } }) });
  assert.deepEqual(await runMailReply({ email }, { native: tools.native, generate: model.generate }), { body: 'Yes.' });
});

test('reads past the budget tell the model to finish without calling Banana', { skip: !available }, async () => {
  const { runMailReply } = await load();
  let reads = 0;
  const model = scripted([(request) => reads++ < 8 ? call('search_mail', { query: 'oak room' }, 'q' + reads) : call('submit_reply', { body: 'Yes.' }, 's1')]);
  const tools = natives();
  const result = await runMailReply({ email }, { native: tools.native, generate: model.generate });
  assert.deepEqual(result, { body: 'Yes.' });
  assert.equal(tools.calls.filter(c => c.name === 'search_mail').length, 6);
  assert.match(model.requests[7].messages.at(-1).text, /Limit reached/);
});

test('rejected checks past the budget stop reaching Banana', { skip: !available }, async () => {
  const { runMailReply } = await load();
  let tries = 0;
  const model = scripted([() => tries++ < 5 ? call('submit_reply', { body: 'It costs $40.' }, 's' + tries) : call('no_reply_needed', { reason: 'Gave up.' }, 'n1')]);
  const tools = natives({ check_reply: () => ({ ok: false, problem: 'Unsupported amount.' }) });
  const result = await runMailReply({ email }, { native: tools.native, generate: model.generate });
  assert.equal(tools.calls.filter(c => c.name === 'check_reply').length, 4);
  assert.deepEqual(result, { noReply: true, reason: 'Gave up.' });
});

test('a model that stops without a finishing tool is nudged once, then the run ends without an outcome', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([{ content: [{ type: 'text', text: 'Sure, here is a reply.' }] }]);
  const result = await runMailReply({ email }, { native: natives().native, generate: model.generate });
  assert.equal(model.requests.length, 2, 'one continuation, not a loop');
  assert.match(model.requests[1].messages.map(m => m.text ?? '').join('\n'), /You have not finished/);
  assert.ok(result.error);
});

test('a nudged model can still finish', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([{ content: [{ type: 'text', text: 'Thinking.' }] }, call('submit_reply', { body: 'Yes.' }, 's1')]);
  assert.deepEqual(await runMailReply({ email }, { native: natives().native, generate: model.generate }), { body: 'Yes.' });
});

test('a proposed time is checked on the calendar before the reply; day words go to native code unchanged', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('check_time', { day: 'Tuesday', start: '15:00', durationMinutes: 45 }, 'c1'), (request) => {
    assert.match(request.messages.at(-1).text, /"available":false/);
    return call('find_free_time', { date: 'Tuesday', durationMinutes: 45 }, 'f1');
  }, call('submit_reply', { body: 'Tuesday at 3 does not work for me; could we do 16:00?' }, 's1')]);
  const tools = natives({ check_time: () => ({ available: false, answer: 'You have a conflict.' }),
    find_free_time: () => ({ windows: [{ date: '2026-11-24', start: '16:00', end: '17:00' }] }) });
  const result = await runMailReply({ email }, { native: tools.native, generate: model.generate });
  assert.equal(result.body, 'Tuesday at 3 does not work for me; could we do 16:00?');
  assert.deepEqual(tools.calls.map(c => c.name), ['check_time', 'find_free_time', 'check_reply']);
  assert.deepEqual(tools.calls[0].args, { day: 'Tuesday', start: '15:00', durationMinutes: 45 });
});

test('calendar reads have their own budget', { skip: !available }, async () => {
  const { runMailReply } = await load();
  let n = 0;
  const model = scripted([() => n++ < 6 ? call('find_free_time', { date: 'today' }, 'f' + n) : call('submit_reply', { body: 'Yes.' }, 's1')]);
  const tools = natives({ find_free_time: () => ({ windows: [] }) });
  await runMailReply({ email }, { native: tools.native, generate: model.generate });
  assert.equal(tools.calls.filter(c => c.name === 'find_free_time').length, 4);
});

test('interactive requests run without thinking even when a level is requested', { skip: !available }, async () => {
  const { runMailReply } = await load();
  const model = scripted([call('submit_reply', { body: 'Yes.' }, 's1')]);
  await runMailReply({ email, provider: 'mac-local', modelId: 'm', thinking: 'low', interactive: true }, { native: natives().native, generate: model.generate });
  assert.equal(model.requests[0].reasoning, 'off');
});

test('outcome mapping', { skip: !available }, async () => {
  const { mailResult } = await load();
  assert.deepEqual(mailResult({}), { error: 'The model finished without a reply.' });
  assert.deepEqual(mailResult({ clarification: 'Which day?' }), { note: 'Which day?' });
});
