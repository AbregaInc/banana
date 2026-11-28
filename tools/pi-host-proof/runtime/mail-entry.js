// Entry for Banana's mail reply runtime (pi-mail.js). Each request opens its own Pi Harness on
// MemoryStorage with the banana-mail extension; Pi owns the step loop, Banana supplies tools and a model.
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { Harness, MemoryStorage, createRegistry } from '@earendil-works/pi-durable';
import { mailExtension, mailInstructions, mailResult } from './mail-reply.js';
export { mailResult };
import { nativeModelProvider, nativeRequest, requestNativeGeneration } from './apple-provider.js';

function nativeTool(request, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason); return; }
    let id, settled = false;
    const finish = (error, value, failed = false) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', abort);
      failed ? reject(error) : resolve(value);
    };
    const abort = () => { nativeToolCancel(id); finish(signal.reason, undefined, true); };
    signal?.addEventListener('abort', abort, { once: true });
    try {
      id = nativeToolStart(JSON.stringify(request), (raw) => {
        try { const result = JSON.parse(raw); result.ok ? finish(null, result.value) : finish(new Error(result.error.message), undefined, true); }
        catch (error) { finish(error, undefined, true); }
      });
    } catch (error) { finish(error, undefined, true); }
  });
}

/// The model this request runs on. Mac-local requests carry reasoning and its budget; Apple's model has neither.
export function mailProvider(request, generate = requestNativeGeneration) {
  const local = request.provider === 'mac-local';
  const contextWindow = request.contextWindow ?? (local ? 32768 : 4096);
  const model = { id: local ? request.modelId : 'on-device', name: local ? 'Local Mac inference' : 'Apple Foundation Models',
    api: local ? 'banana-mac-local' : 'banana-apple-foundation', provider: local ? 'mac-local' : 'apple-foundation',
    baseUrl: local ? 'mac-local://inference' : 'apple-local://foundation-models', reasoning: local, input: ['text'],
    contextWindow, maxTokens: request.maxTokens ?? Math.min(local ? 3072 : 1024, contextWindow),
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const buildRequest = (ctx, options) => ({ ...nativeRequest(ctx, options, local),
    ...(local ? { backend: 'mac-local', modelId: model.id } : {}),
    ...(local && request.reasoningBudget ? { reasoningBudget: request.reasoningBudget } : {}) });
  return { model, provider: nativeModelProvider({ model, generate, buildRequest, name: model.name,
    toolChoice: request.toolChoice ?? 'required' }) };
}

function emailText(email) {
  return JSON.stringify({ subject: email.subject, from: email.fromName ? `${email.fromName} <${email.from}>` : email.from,
    to: 'the owner (' + email.account + ')', replyGoesTo: email.to, cc: email.cc, email: email.email });
}

/// One reply: resolves to {body} | {questions, reply} | {note} | {noReply, reason} | {error}.
export async function runMailReply(request, { native = nativeTool, generate = requestNativeGeneration, timeLimit } = {}) {
  const outcome = {};
  const { model, provider } = mailProvider(request, generate);
  const models = createModels();
  models.setProvider(provider);
  const registry = createRegistry();
  registry.install(mailExtension(native, outcome, request.picker !== false));
  const harness = await Harness.open(new MemoryStorage(), { models, registry, onReport: (error) => console.error(String(error)) }, context);
  try {
    const thinkingLevel = model.reasoning ? (request.thinking ?? 'off') : 'off';
    const root = await harness.root(context, { agent: { model: { provider: model.provider, modelId: model.id }, thinkingLevel, instructions: mailInstructions } });
    const submission = await root.submit({ type: 'input', requestId: request.requestId ?? 'mail-reply',
      content: (request.task || 'Write my reply.') + '\n\nSelected email (data):\n' + emailText(request.email) }, context);
    const limit = (timeLimit ?? request.timeLimitSeconds ?? 180) * 1000;
    let timer;
    const settled = await Promise.race([submission.wait(context),
      new Promise(resolve => { timer = setTimeout(() => resolve({ status: 'timeout' }), limit); })]);
    clearTimeout(timer);
    if (settled?.status === 'timeout' && !outcome.body && !outcome.clarification) return { error: 'The reply took too long.' };
    return mailResult(outcome);
  } finally {
    await Promise.race([harness.close(context), new Promise(resolve => setTimeout(resolve, 5000))]);
  }
}

globalThis.bananaMailReply = (raw, done) => {
  let request;
  try { request = JSON.parse(raw); } catch { done(JSON.stringify({ error: 'Invalid mail reply request.' })); return; }
  runMailReply(request).then(result => done(JSON.stringify(result)), error => done(JSON.stringify({ error: String(error?.message ?? error) })));
};
