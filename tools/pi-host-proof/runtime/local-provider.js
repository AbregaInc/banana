import { routeGeneration } from './capability-routing.js';
import { nativeModelProvider, nativeRequest, requestNativeGeneration } from './apple-provider.js';

// Inference only. Application capabilities continue to run as Pi extension tasks.
export function macLocalProvider(configuration, generate, pairedRecipient) {
  const model = { id: configuration.modelId, name: configuration.name, api: 'banana-mac-local',
    provider: 'mac-local', baseUrl: 'mac-local://inference', reasoning: true, input: ['text'],
    contextWindow: configuration.contextWindow, maxTokens: configuration.maxTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  return nativeModelProvider({ model, name: 'Local Mac inference', generate: async (request, signal) => {
    if (!pairedRecipient) return routeGeneration(request,generate ?? requestNativeGeneration,signal);
    const {sessionId,...input} = request;
    const recipient = await pairedRecipient(sessionId);
    if (!recipient) {
      // A pre-migration queued generation may still name the old Mac model. Resume the same
      // inference locally; its durable tool tasks and their effect IDs are unchanged.
      const {backend,modelId,reasoning,...device} = input;
      device.maxTokens = Math.min(device.maxTokens,1024);
      device.messages = device.messages.map(message => message.role === 'assistant'
        ? {...message,content:message.content.filter(part => part.type !== 'thinking')} : message);
      return routeGeneration(device,generate ?? requestNativeGeneration,signal);
    }
    input.tools = input.tools.filter(tool => !['read_mail_thread','read_mail_inbox'].includes(tool.name));
    return routeGeneration(input, async (step,abort) => {
      // Check again at the actual transport boundary, including compaction and resumed tasks.
      if (await pairedRecipient(sessionId) !== recipient) throw new Error('This conversation can only use the on-device model.');
      return (generate ?? requestNativeGeneration)({...step,pairedRecipient:recipient},abort);
    },signal);
  },
    buildRequest: (context, options) => ({ ...nativeRequest(context, options, true), backend: 'mac-local', modelId: model.id, ...(pairedRecipient ? {sessionId:options.sessionId} : {}) }),
  });
}
