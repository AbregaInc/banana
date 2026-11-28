// Shared pieces for Banana's Pi extensions. Pi owns the loop; these are plugin parts an extension
// installs on it: tool results, a once-only finish nudge, per-task tool budgets, and the provider and
// thinking options a task asks for. Measured on mail replies with Gemma 4 26B (see mail-reply.js).
import { hook, GenerationTask } from '@earendil-works/pi-durable';

/// A tool result the model reads as JSON.
export const toolText = (value) => ({ output: [{ type: 'text', text: JSON.stringify(value) }] });

/// A tool result that ends the task: the finishing tool's outcome is the answer.
export const finishWith = (value) => ({ ...toolText(value), control: { terminate: true } });

/// A task that must end in one of its finishing tools. If the model yields without one, Pi continues
/// once with this message; a second yield ends the task (the caller reports no answer).
export function finishNudge(isFinished, message) {
  let nudged = false;
  return hook(GenerationTask, { onYield: async () => {
    if (isFinished() || nudged) return undefined;
    nudged = true;
    return { continue: message };
  } });
}

/// Per-task tool budgets: spend(kind) counts one use and answers true once the kind is over its limit.
/// exhausted is the tool result that tells the model to finish with what it has.
export function toolBudget(limits, message) {
  const used = {};
  return {
    spend: (kind) => (used[kind] = (used[kind] ?? 0) + 1) > (limits[kind] ?? Infinity),
    used: (kind) => used[kind] ?? 0,
    exhausted: toolText({ error: message }),
  };
}

/// Provider options for a task. A task that always finishes in a tool asks the provider to constrain
/// every turn to a tool call ('required'): Gemma on mlx-serve otherwise writes calls as plain text,
/// which the server does not parse. Chat may answer in text, so it keeps the provider default.
export function toolChoiceFor({ finishesWithTool }) {
  return finishesWithTool ? 'required' : undefined;
}

/// Thinking per task: off while the owner waits (interactive), the requested level in the background.
/// A model without reasoning is always off.
export function thinkingFor(model, { interactive, requested }) {
  if (!model.reasoning || interactive) return 'off';
  return requested ?? 'low';
}
