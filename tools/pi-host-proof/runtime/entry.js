import { runWorkspaceConformance } from './workspace-conformance.js';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxProvider, fauxAssistantMessage, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';
import { Type } from 'typebox';
import { Harness, MemoryStorage, createRegistry, defineExtension, defineTool } from '@earendil-works/pi-durable';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';
import { runNutritionConformance } from './nutrition-conformance.js';
import { runHostConformance } from './conformance.js';
import { runFoundationProof } from './foundation-proof.js';
import { runProviderConformance } from './provider-conformance.js';
import { runLifecycleProof } from './lifecycle-proof.js';
import { runLifecycleConformance } from './lifecycle-conformance.js';
import { runHandoffProof } from './handoff-proof.js';

globalThis.runPiSmoke = async function () {
  if (nativeMode === 'workspace-conformance') return runWorkspaceConformance();
  if (nativeMode === 'nutrition-conformance') return runNutritionConformance();
  if (nativeMode === 'host-conformance') return runHostConformance();
  if (nativeMode === 'provider-conformance') return runProviderConformance();
  if (nativeMode.startsWith('foundation-')) return runFoundationProof();
  if (nativeMode === 'lifecycle-conformance') return runLifecycleConformance();
  if (nativeMode.startsWith('lifecycle-')) return runLifecycleProof();
  if (nativeMode.startsWith('handoff-')) return runHandoffProof();
  const models = createModels(), faux = fauxProvider();
  models.setProvider(faux.provider);
  const recovering = nativeMode.endsWith('reopen');
  faux.setResponses(recovering ? [fauxAssistantMessage('Recovered on Apple JavaScriptCore.')] : [
    fauxAssistantMessage([fauxToolCall('banana_probe', { value: 21 }, { id: 'probe-1' })], { stopReason: 'toolUse' }),
    fauxAssistantMessage('The Banana bridge returned 42.'),
  ]);
  let calls = 0;
  const registry = createRegistry();
  // Native application capabilities are registered through Pi's public extension API.
  registry.install(defineExtension({ name: 'banana-proof', tools: [defineTool({
    name: 'banana_probe', description: 'Test a native Banana capability.',
    parameters: Type.Object({ value: Type.Number() }),
    execute: async (args) => { calls++; return { output: [{ type: 'text', text: String(nativeDouble(args.value)) }] }; },
  })] }));
  const storage = nativeMode === 'memory' ? new MemoryStorage() : await SqliteStorage.open(new NativeDatabase());
  const harness = await Harness.open(storage, { models, registry,
    onReport: (error, info) => nativeLog(JSON.stringify({ error: String(error), info })),
  }, BACKGROUND_CONTEXT);
  const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider: 'faux', modelId: 'faux-1' } } });
  const requestId = nativeMode.startsWith('crash') ? 'apple-crash' : 'apple-smoke';
  const request = { type: 'input', content: 'Double 21.', requestId };
  const submission = await root.submit(request, BACKGROUND_CONTEXT);
  const settled = await submission.wait(BACKGROUND_CONTEXT);
  const duplicate = await root.submit(request, BACKGROUND_CONTEXT);
  const entries = await root.entries({}, 100, undefined, BACKGROUND_CONTEXT);
  await harness.close(BACKGROUND_CONTEXT);
  const interrupted = entries.items.some((entry) => entry.model?.some((message) => message.role === 'toolResult' && message.isError && JSON.stringify(message).includes('interrupted')));
  return { mode: nativeMode, status: settled.status, calls, deduplicated: duplicate.id === submission.id,
    interrupted, passed: settled.status === 'done' && duplicate.id === submission.id && calls === (recovering ? 0 : 1) && (nativeMode !== 'crash-reopen' || interrupted),
    kinds: entries.items.map((entry) => entry.kind).reverse(),
    results: entries.items.filter((entry) => entry.kind === 'pi.tool-result').map((entry) => entry.model) };
};
