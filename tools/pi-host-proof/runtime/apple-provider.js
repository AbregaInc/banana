import { createProvider } from '@earendil-works/pi-ai/models';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';
import { getCurrentSystemPrompt, getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';

// Each native call is one generation. It never executes application capabilities.
export function requestNativeGeneration(request, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason); return; }
    let id, settled = false;
    const finish = (error, value, failed = false) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', abort);
      failed ? reject(error) : resolve(value);
    };
    const abort = () => { nativeModelCancel(id); finish(signal.reason, undefined, true); };
    signal?.addEventListener('abort', abort, { once: true });
    try {
      id = nativeModelStart(JSON.stringify(request), (raw) => {
        try {
          const result = JSON.parse(raw);
          if (!result.ok) { const error = new Error(result.error.message); error.code = result.error.code; finish(error, undefined, true); }
          else finish(null, result.value);
        } catch (error) { finish(error, undefined, true); }
      });
    } catch (error) { finish(error, undefined, true); }
  });
}

function textContent(content) {
  if (typeof content === 'string') return content;
  return content.map((part) => {
    if (part.type !== 'text') throw new Error(`Apple provider does not support ${part.type} input`);
    return part.text;
  }).join('\n');
}

export function nativeRequest(context, options = {}, allowReasoning = false) {
  if (!allowReasoning && options.reasoning !== undefined && options.reasoning !== 'off') throw new Error('Apple provider does not expose reasoning controls');
  if (options.thinkingBudgets !== undefined) throw new Error('Apple provider does not expose thinking budgets');
  if (options.deferred) throw new Error('Apple provider does not support deferred inference');
  if (options.toolChoice !== undefined && !['auto', 'none'].includes(options.toolChoice)) throw new Error('Unsupported Apple tool choice');
  if (options.maxTokens !== undefined && (!Number.isSafeInteger(options.maxTokens) || options.maxTokens < 1)) throw new Error('Invalid Apple maxTokens');
  if (options.temperature !== undefined && (!Number.isFinite(options.temperature) || options.temperature < 0)) throw new Error('Invalid Apple temperature');
  return {
    instructions: getCurrentSystemPrompt(context.messages),
    tools: options.toolChoice === 'none' ? [] : getCurrentTools(context.messages),
    messages: context.messages.filter((message) => message.role !== 'system').map((message) => {
      if (message.role === 'assistant') {
        return { role: 'assistant', content: message.content.map((part) => {
          if (!allowReasoning && part.type === 'thinking') throw new Error('Apple provider cannot replay reasoning blocks');
          return part;
        }) };
      }
      if (message.role === 'user') return { role: 'user', text: textContent(message.content) };
      return { role: 'toolResult', toolCallId: message.toolCallId, toolName: message.toolName,
        text: textContent(message.content), isError: message.isError };
    }),
    ...(allowReasoning ? { reasoning: options.reasoning ?? 'off' } : {}),
    ...(options.temperature === undefined ? {} : { temperature: options.temperature }),
    ...(options.maxTokens === undefined ? {} : { maxTokens: options.maxTokens }),
  };
}

export function appleRequest(context, options = {}) { return nativeRequest(context, options); }

export function appleFoundationProvider({ generate = requestNativeGeneration, contextWindow = 4096 } = {}) {
  const model = { id: 'on-device', name: 'Apple Foundation Models (on device)', api: 'banana-apple-foundation',
    provider: 'apple-foundation', baseUrl: 'apple-local://foundation-models', reasoning: false, input: ['text'],
    contextWindow, maxTokens: Math.min(1024, contextWindow), cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  return nativeModelProvider({ model, generate, buildRequest: appleRequest, name: 'Apple Foundation Models' });
}

// Public Pi provider adapter shared by Apple's model and the separate local Mac engine.
export function nativeModelProvider({ model, generate = requestNativeGeneration, buildRequest, name }) {
  const stream = (selected, context, options = {}) => {
    const events = createAssistantMessageEventStream();
    const message = { role: 'assistant', content: [], api: selected.api, provider: selected.provider, model: selected.id,
      timestamp: Date.now(), stopReason: 'pending', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
        totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    queueMicrotask(async () => {
      try {
        options.signal?.throwIfAborted();
        const request = buildRequest(context, options);
        request.maxTokens = Math.min(request.maxTokens ?? selected.maxTokens, selected.maxTokens);
        const result = await generate(request, options.signal);
        options.signal?.throwIfAborted();
        if (!result || !Array.isArray(result.content) || result.content.length === 0) throw new Error('Empty Apple model response');
        const tools = new Map(request.tools.map((tool) => [tool.name, tool]));
        const ids = new Set();
        for (const part of result.content) {
          if (part.type === 'text' && typeof part.text === 'string') continue;
          if (model.reasoning && part.type === 'thinking' && typeof part.thinking === 'string') continue;
          if (part.type !== 'toolCall' || !tools.has(part.name) || typeof part.id !== 'string' || !part.id || ids.has(part.id)
              || !part.arguments || typeof part.arguments !== 'object' || Array.isArray(part.arguments)) throw new Error('Invalid Apple model tool call');
          ids.add(part.id);
        }
        events.push({ type: 'start', partial: message });
        for (const part of result.content) {
          const index = message.content.length;
          if (part.type === 'thinking') {
            message.content.push({ type: 'thinking', thinking: '' });
            events.push({ type: 'thinking_start', contentIndex: index, partial: message });
            message.content[index].thinking = part.thinking;
            events.push({ type: 'thinking_delta', contentIndex: index, delta: part.thinking, partial: message });
            events.push({ type: 'thinking_end', contentIndex: index, content: part.thinking, partial: message });
          } else if (part.type === 'text') {
            message.content.push({ type: 'text', text: '' });
            events.push({ type: 'text_start', contentIndex: index, partial: message });
            message.content[index].text = part.text;
            events.push({ type: 'text_delta', contentIndex: index, delta: part.text, partial: message });
            events.push({ type: 'text_end', contentIndex: index, content: part.text, partial: message });
          } else {
            message.content.push({ type: 'toolCall', id: part.id, name: part.name, arguments: {} });
            events.push({ type: 'toolcall_start', contentIndex: index, partial: message });
            events.push({ type: 'toolcall_delta', contentIndex: index, delta: JSON.stringify(part.arguments), partial: message });
            message.content[index].arguments = part.arguments;
            events.push({ type: 'toolcall_end', contentIndex: index, toolCall: part, partial: message });
          }
        }
        // Token usage is unknown on the capture/error path. Zero means unreported, never an estimate.
        message.stopReason = ids.size ? 'toolUse' : 'stop';
        events.push({ type: 'done', reason: message.stopReason, message });
        events.end(message);
      } catch (error) {
        message.stopReason = options.signal?.aborted ? 'aborted' : 'error';
        message.errorMessage = String(error);
        events.push({ type: 'error', reason: message.stopReason, error: message });
        events.end(message);
      }
    });
    return events;
  };
  return createProvider({ id: model.provider, name, models: [model],
    auth: { apiKey: { name: 'On-device availability', resolve: async () => ({ auth: {} }) } },
    api: { stream, streamSimple: stream } });
}
