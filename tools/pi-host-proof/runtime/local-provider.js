import { routeGeneration } from './capability-routing.js';
import { nativeModelProvider, nativeRequest, requestNativeGeneration } from './apple-provider.js';

// Inference only. Application capabilities continue to run as Pi extension tasks.
export function macLocalProvider(configuration, generate) {
  const model = { id: configuration.modelId, name: configuration.name, api: 'banana-mac-local',
    provider: 'mac-local', baseUrl: 'mac-local://inference', reasoning: true, input: ['text'],
    contextWindow: configuration.contextWindow, maxTokens: configuration.maxTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  return nativeModelProvider({ model, name: 'Local Mac inference', generate: (request, signal) => routeGeneration(request, generate ?? requestNativeGeneration, signal),
    buildRequest: (context, options) => ({ ...nativeRequest(context, options, true), backend: 'mac-local', modelId: model.id }),
  });
}
