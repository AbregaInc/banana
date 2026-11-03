import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { Type } from 'typebox';
import { Harness, createRegistry, defineExtension, defineTool } from '@earendil-works/pi-durable';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';
import { appleFoundationProvider, requestNativeGeneration } from './apple-provider.js';

export async function runFoundationProof() {
  const availability = JSON.parse(nativeModelStatus());
  if (!availability.available) return { mode: nativeMode, passed: false, unavailable: true, availability };
  let modelCalls = 0, toolCalls = 0;
  const textOnly = nativeMode === 'foundation-text', reopening = nativeMode.endsWith('reopen');
  const interruptedRecovery = nativeMode === 'foundation-crash-reopen';
  const models = createModels();
  models.setProvider(appleFoundationProvider({ contextWindow: availability.contextWindow, generate: (request, signal) => {
    if (++modelCalls > 4) throw new Error('Proof exceeded four model calls');
    return requestNativeGeneration(request, signal);
  } }));
  const registry = createRegistry();
  if (!textOnly) registry.install(defineExtension({ name: 'banana-local-proof', tools: [defineTool({
    name: 'banana_probe', description: 'Double a number using the native device capability. Call once for a doubling request.',
    parameters: Type.Object({ value: Type.Number() }, { additionalProperties: false }),
    execute: async ({ value }) => {
      if (++toolCalls > 1) throw new Error('Proof tool may only execute once');
      return { output: [{ type: 'text', text: String(nativeDouble(value)) }] };
    },
  })] }));
  const storage = await SqliteStorage.open(new NativeDatabase());
  const harness = await Harness.open(storage, { models, registry, onReport: (error) => nativeLog(String(error)) }, BACKGROUND_CONTEXT);
  try {
    const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider: 'apple-foundation', modelId: 'on-device' } } });
    const input = { type: 'input', requestId: textOnly ? 'foundation-text' : 'foundation-tool',
      content: textOnly ? 'Reply with a short greeting.' : 'Use banana_probe exactly once with value 21. Then tell me the result returned by the tool. Do not compute it yourself or call the tool again.' };
    const submission = await root.submit(input, BACKGROUND_CONTEXT);
    const settled = await submission.wait(BACKGROUND_CONTEXT);
    const duplicate = await root.submit(input, BACKGROUND_CONTEXT);
    const entries = await root.entries({}, 100, undefined, BACKGROUND_CONTEXT);
    const messages = entries.items.flatMap((entry) => entry.model ?? []);
    const assistants = messages.filter((message) => message.role === 'assistant');
    const answer = assistants.flatMap((message) => message.content.filter((block) => block.type === 'text').map((block) => block.text));
    const errors = assistants.filter((message) => message.stopReason === 'error' || message.stopReason === 'aborted').map((message) => message.errorMessage);
    const interrupted = messages.some((message) => message.role === 'toolResult' && message.isError && JSON.stringify(message).includes('interrupted'));
    const deduplicated = duplicate.id === submission.id;
    return { mode: nativeMode, availability, modelCalls, toolCalls, status: settled.status, deduplicated, interrupted, answer, errors,
      passed: settled.status === 'done' && deduplicated && errors.length === 0 && answer.some((text) => text.trim())
        && (textOnly ? toolCalls === 0 : interruptedRecovery ? interrupted && toolCalls === 0 && modelCalls === 1
          : reopening ? toolCalls === 0 && modelCalls === 0 : toolCalls === 1 && answer.some((text) => text.includes('42'))),
      results: messages.filter((message) => message.role === 'toolResult') };
  } finally { await harness.close(BACKGROUND_CONTEXT); }
}
