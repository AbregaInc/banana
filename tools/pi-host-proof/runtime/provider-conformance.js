import { expect } from 'chai';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { Harness, MemoryStorage, ProviderDoc, createRegistry, defineExtension, defineTool } from '@earendil-works/pi-durable';
import { Type } from 'typebox';
import {SqliteStorage} from '@earendil-works/pi-durable/storage/sqlite';
import {NativeDatabase} from './database.js';
import { normalizeContext } from '@earendil-works/pi-ai/utils/transcript';
import { appleFoundationProvider, appleRequest, requestNativeGeneration } from './apple-provider.js';
import {grantFreshConversation, conversationPeerAllowed, keepEvidenceOnDevice, peerAllowed} from './peer-inference.js';
import { macLocalProvider } from './local-provider.js';

export async function runProviderConformance() {
  const results = [];
  const check = async (name, run) => {
    try { await run(); results.push({ name, passed: true }); }
    catch (error) { results.push({ name, passed: false, error: String(error), stack: error.stack }); }
    nativeLog(`${results.at(-1).passed ? 'PASS' : 'FAIL'} ${name}`);
  };
  const setup = (generate) => {
    const models = createModels();
    models.setProvider(appleFoundationProvider({ generate }));
    return { models, stream: (context, options) => models.streamSimple(models.getModel('apple-foundation', 'on-device'), context, options) };
  };
  const input = { messages: [{ role: 'user', content: 'hello', timestamp: 1 }] };
  await check('local provider preserves reasoning and has a distinct durable model identity', async () => {
    const models = createModels();
    models.setProvider(macLocalProvider({ modelId: 'test-local', name: 'Test local', contextWindow: 32768, maxTokens: 8192 }, async (request) => {
      expect(request.backend).to.equal('mac-local');
      expect(request.modelId).to.equal('test-local');
      expect(request.reasoning).to.equal('medium');
      expect(request.maxTokens).to.equal(8192);
      expect(request.messages[0].content[0]).to.deep.equal({ type: 'thinking', thinking: 'Earlier reasoning' });
      return { content: [{ type: 'thinking', thinking: 'Local reasoning' }, { type: 'text', text: 'Answer' }] };
    }));
    const events = models.streamSimple(models.getModel('mac-local', 'test-local'), { messages: [
      { role: 'assistant', content: [{ type: 'thinking', thinking: 'Earlier reasoning' }, { type: 'text', text: 'Earlier answer' }] }, ...input.messages,
    ] }, { reasoning: 'medium' });
    const types = [];
    for await (const event of events) types.push(event.type);
    expect(types).to.deep.equal(['start', 'thinking_start', 'thinking_delta', 'thinking_end', 'text_start', 'text_delta', 'text_end', 'done']);
    const result = await events.result();
    expect(result.provider).to.equal('mac-local');
    expect(result.model).to.equal('test-local');
    expect(result.content[0].thinking).to.equal('Local reasoning');
  });
  await check('paired generation requires persisted authorization for the actual session and recipient', async () => {
    const ctx = BACKGROUND_CONTEXT;
    const storage = () => SqliteStorage.open(new NativeDatabase());
    const models = createModels();
    const peer = 'fixture-peer';
    let owner;
    const sent = [];
    models.setProvider(macLocalProvider({modelId:'paired',name:'Paired fixture',contextWindow:8192,maxTokens:1024},
      async request => {
        sent.push(request);
        return {content:[{type:'text',text:'Fixture answer'}]};
      },async id => await peerAllowed(owner,id,peer,ctx) ? peer : undefined));
    owner = await Harness.open(await storage(),{models,registry:createRegistry()},ctx);
    try {
      const root = await owner.root(ctx);
      const conversation = await owner.createConversation({ownership:{kind:'ownerless'}},ctx);
      await grantFreshConversation(owner,conversation.id,peer,ctx);
      const id = (await owner.snapshot(ProviderDoc,conversation.id,ctx)).sessionId;
      expect(await conversationPeerAllowed(owner,root.id,peer,ctx)).to.equal(false);
      expect(await peerAllowed(owner,id,'another-peer',ctx)).to.equal(false);
      const model = models.getModel('mac-local','paired');
      // Compaction/recovery can contain sensitive information with no remaining mail tool call.
      const history = {messages:[{role:'assistant',content:[{type:'text',text:'Synthetic summary of a private excerpt'}]},
        {role:'user',content:'What did that mean?',timestamp:1}]};
      const run = async sessionId => {
        sent.length = 0;
        const result = await models.streamSimple(model,history,{sessionId}).result();
        expect(result.stopReason).to.equal('stop');
        expect(sent.length).to.be.greaterThan(0);
        return sent.map(request => request.pairedRecipient);
      };
      expect(await run('legacy-session')).to.deep.equal([undefined]);
      expect(await run(id)).to.deep.equal([peer]);
      await keepEvidenceOnDevice(owner,conversation.id,ctx);
      expect(await run(id)).to.deep.equal([undefined]);
      // Reopening reads the durable grant, and retrying new-conversation setup cannot undo revocation.
      await owner.close(ctx);
      owner = await Harness.open(await storage(),{models,registry:createRegistry()},ctx);
      await grantFreshConversation(owner,conversation.id,peer,ctx);
      expect(await run(id)).to.deep.equal([undefined]);
    } finally { await owner.close(ctx); }
  });
  await check('Apple resumes visible history from the Mac without private model reasoning', () => {
    const note = {type:'toolCall',id:'example',name:'list_notes',arguments:{}};
    const blocks = [{type:'thinking',thinking:'Mac-only reasoning'},{type:'text',text:'Previous answer'},note];
    const request = appleRequest({messages:[{role:'assistant',provider:'mac-local',content:blocks}]});
    expect(request.messages[0].content).to.deep.equal(blocks.slice(1));
    expect(blocks).to.have.length(3);
  });
  await check('public provider emits a valid text event sequence', async () => {
    const { stream } = setup(async () => ({ content: [{ type: 'text', text: 'Local hello 🍌' }] }));
    const events = stream(input), types = [];
    for await (const event of events) types.push(event.type);
    expect(types).to.deep.equal(['start', 'text_start', 'text_delta', 'text_end', 'done']);
    const result = await events.result();
    expect(result.content[0].text).to.equal('Local hello 🍌');
    expect(result.stopReason).to.equal('stop');
  });
  await check('Pi executes extension tools only after provider returns intent', async () => {
    let calls = 0, generations = 0;
    const { models } = setup(async (request) => {
      if (++generations === 1) {
        expect(calls).to.equal(0);
        expect(request.tools.map((tool) => tool.name)).to.include('banana_probe');
        return { content: [{ type: 'toolCall', id: 'native-intent-1', name: 'banana_probe', arguments: { value: 21 } }] };
      }
      expect(calls).to.equal(1);
      expect(request.messages.some((message) => message.role === 'toolResult' && message.toolCallId === 'native-intent-1' && message.text === '42')).to.equal(true);
      return { content: [{ type: 'text', text: '42' }] };
    });
    const registry = createRegistry();
    registry.install(defineExtension({ name: 'test-apple-extension', tools: [defineTool({ name: 'banana_probe', description: 'Double a number.',
      parameters: Type.Object({ value: Type.Number() }), execute: async ({ value }) => {
        calls++; return { output: [{ type: 'text', text: String(value * 2) }] };
      } })] }));
    const harness = await Harness.open(new MemoryStorage(), { models, registry }, BACKGROUND_CONTEXT);
    try {
      const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider: 'apple-foundation', modelId: 'on-device' } } });
      const request = { type: 'input', content: 'Double 21', requestId: 'provider-contract' };
      const submission = await root.submit(request, BACKGROUND_CONTEXT);
      expect((await submission.wait(BACKGROUND_CONTEXT)).status).to.equal('done');
      expect((await root.submit(request, BACKGROUND_CONTEXT)).id).to.equal(submission.id);
      expect(calls).to.equal(1);
      expect(generations).to.equal(2);
    } finally { await harness.close(BACKGROUND_CONTEXT); }
  });
  await check('upstream system/tool replay preserves updates and removes revoked tools', () => {
    const request = appleRequest({ messages: [
      { role: 'system', content: 'base', sections: { rules: 'old' }, toolsAdded: [{ name: 'old' }] },
      { role: 'system', content: 'extra', sections: { rules: 'new' }, toolsRemoved: [{ name: 'old' }], toolsAdded: [{ name: 'new' }] },
      { role: 'user', content: 'hello' },
    ] });
    expect(request.instructions).to.equal('base\n\nextra\n\nnew');
    expect(request.tools.map((tool) => tool.name)).to.deep.equal(['new']);
    expect(request.messages).to.deep.equal([{ role: 'user', text: 'hello' }]);
  });
  await check('unsupported images fail before native inference', async () => {
    let called = false;
    const { stream } = setup(async () => { called = true; });
    const result = await stream({ messages: [{ role: 'user', content: [{ type: 'image', data: '', mimeType: 'image/png' }] }] }).result();
    expect(result.stopReason).to.equal('error');
    expect(called).to.equal(false);
  });
  await check('invalid generation options fail before native inference', async () => {
    let called = false;
    const { stream } = setup(async () => { called = true; });
    for (const options of [{ maxTokens: 0 }, { maxTokens: 1.5 }, { temperature: NaN }, { reasoning: 'high' }, { deferred: true }]) {
      expect((await stream(input, options).result()).stopReason).to.equal('error');
    }
    expect(called).to.equal(false);
  });
  await check('toolChoice none removes tools and rejects unexpected native tool calls', async () => {
    const { stream } = setup(async (request) => {
      expect(request.tools).to.deep.equal([]);
      return { content: [{ type: 'toolCall', id: 'forbidden', name: 'known', arguments: {} }] };
    });
    const result = await stream({ ...input, tools: [{ name: 'known', description: '', parameters: Type.Object({}) }] }, { toolChoice: 'none' }).result();
    expect(result.stopReason).to.equal('error');
  });
  await check('native model errors are terminal provider errors', async () => {
    const { stream } = setup(async () => { throw new Error('model unavailable probe'); });
    const events = stream(input), types = [];
    for await (const event of events) types.push(event.type);
    expect(types).to.deep.equal(['error']);
    expect((await events.result()).errorMessage).to.include('model unavailable probe');
  });
  await check('unknown tool names and duplicate call IDs fail closed', async () => {
    for (const content of [
      [{ type: 'toolCall', id: 'a', name: 'unknown', arguments: {} }],
      [1, 2].map(() => ({ type: 'toolCall', id: 'same', name: 'known', arguments: {} })),
    ]) {
      const { stream } = setup(async () => ({ content }));
      expect((await stream({ ...input, tools: [{ name: 'known', description: '', parameters: Type.Object({}) }] }).result()).stopReason).to.equal('error');
    }
  });
  await check('pre-aborted requests never enter native generation', async () => {
    let calls = 0;
    const { stream } = setup(async () => { calls++; });
    const result = await stream(input, { signal: AbortSignal.abort('cancelled') }).result();
    // Upstream Models maps cancellation during auth setup to an error event.
    // The provider itself must retain its aborted classification.
    expect(result.stopReason).to.equal('error');
    const provider = appleFoundationProvider({ generate: async () => { calls++; } });
    const direct = await provider.streamSimple(provider.getModels()[0], normalizeContext(input), { signal: AbortSignal.abort('cancelled') }).result();
    expect(direct.stopReason).to.equal('aborted');
    expect(calls).to.equal(0);
  });
  await check('RPC cancellation cancels native work and ignores a late callback', async () => {
    const originalStart = nativeModelStart, originalCancel = nativeModelCancel;
    let callback, cancelled;
    try {
      globalThis.nativeModelStart = (_, complete) => { callback = complete; return 71; };
      globalThis.nativeModelCancel = (id) => { cancelled = id; };
      const controller = new AbortController();
      const promise = requestNativeGeneration({}, controller.signal);
      controller.abort(0);
      let rejected = false;
      try { await promise; } catch (reason) { rejected = true; expect(reason).to.equal(0); }
      expect(rejected).to.equal(true);
      expect(cancelled).to.equal(71);
      callback(JSON.stringify({ ok: true, value: { content: [] } }));
    } finally { globalThis.nativeModelStart = originalStart; globalThis.nativeModelCancel = originalCancel; }
  });
  await check('native schema translation accepts supported types and rejects lossy mappings', () => {
    const valid = Type.Object({ n: Type.Number(), list: Type.Array(Type.String()), enabled: Type.Optional(Type.Boolean()) }, { additionalProperties: false });
    expect(JSON.parse(nativeModelValidateSchema(JSON.stringify(valid))).ok).to.equal(true);
    for (const invalid of [{ type: 'string', pattern: '^x$' }, { anyOf: [{ type: 'string' }, { type: 'number' }] },
      { type: 'object', properties: {}, additionalProperties: true }, { type: 'number', minimum: 3 },
      { type: 'object', properties: {}, required: 'invalid' }]) {
      expect(JSON.parse(nativeModelValidateSchema(JSON.stringify(invalid))).ok).to.equal(false);
    }
  });
  const failed = results.filter((result) => !result.passed);
  return { mode: nativeMode, passed: failed.length === 0, total: results.length, failed, results, availability: JSON.parse(nativeModelStatus()) };
}
