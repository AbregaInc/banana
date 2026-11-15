import { defineDoc, defineExtension, defineTool, section, hook, GenerationTask } from '@earendil-works/pi-durable';
import { getCurrentSystemMessage } from '@earendil-works/pi-ai/utils/transcript';
import { Type } from 'typebox';

export const NutritionDoc = defineDoc({
  kind: 'banana.nutrition-surface', version: 1, scope: 'conversation', history: 'latest', fork: 'current',
  initial: () => ({ revision: 0, surface: null, operation: null, inputId: null }), checkpointWhen: () => true,
});

const fields = {
  period: Type.Optional(Type.String({ enum: ['this_month', 'last_month', 'last_7_days', 'last_30_days'], description: 'Use for relative calendar requests; native code resolves dates. this_month starts on the first of this month.' })),
  metric: Type.Optional(Type.String({ enum: ['protein', 'calories', 'carbs', 'fat'], description: 'The nutrient to chart. A nutrient is not a food-name search.' })),
  start: Type.Optional(Type.String()), end: Type.Optional(Type.String()),
  weekdaysOnly: Type.Optional(Type.Boolean()), compare: Type.Optional(Type.Boolean()),
  search: Type.Optional(Type.String({ description: 'Only explicitly requested food or meal names, such as yogurt. Empty means all foods. Never use nutrient names or date words as a food search.' })),
  selectedDay: Type.Optional(Type.String({ description: 'Use an empty string to clear this field.' })),
  draftMealID: Type.Optional(Type.String({ description: 'Use an empty string to clear this field.' })),
  draftDate: Type.Optional(Type.String({ description: 'Use an empty string to clear this field.' })),
  draftRelativeDay: Type.Optional(Type.String()),
};

function dateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export async function updateNutrition(owner, conversationId, patch, operation, nativeTool, ctx, { readOnly = false, inputId = null } = {}) {
  const before = await owner.snapshot(NutritionDoc, conversationId, ctx);
  if (before?.operation === operation) return before.surface;
  const revision = before?.revision ?? 0;
  if (patch.revision !== revision) throw new Error('The view changed. Read the current nutrition view and try again.');
  const now = new Date();
  const start = new Date(now); start.setDate(1);
  const surface = { metric: 'protein', start: dateKey(start), end: dateKey(now), weekdaysOnly: false,
    compare: false, search: '', ...before?.surface };
  for (const key of Object.keys(fields)) if (Object.hasOwn(patch, key)) surface[key] = patch[key];
  // A new range/filter discards a day or draft that may no longer be visible.
  if (['period', 'start', 'end', 'weekdaysOnly', 'search'].some((key) => Object.hasOwn(patch, key))) {
    if (!Object.hasOwn(patch, 'selectedDay')) surface.selectedDay = null;
    if (!Object.hasOwn(patch, 'draftMealID')) { surface.draftMealID = null; surface.draftDate = null; }
  }
  for (const key of ['selectedDay', 'draftMealID', 'draftDate']) if (surface[key] === '') surface[key] = null;
  if (surface.draftMealID && Object.hasOwn(patch, 'draftMealID')) surface.draftID = operation;
  if (!surface.draftMealID) delete surface.draftID;
  surface.revision = revision + 1;
  const validated = await nativeTool({ name: 'nutrition_view', arguments: surface }, ctx.abortSignal);
  if (readOnly) return validated;
  await owner.commit(async (tx) => {
    const doc = await tx.doc(NutritionDoc, conversationId);
    if (doc.operation === operation) return;
    if (doc.revision !== revision) throw new Error('The view changed while interpreting this request. Try again.');
    doc.revision = surface.revision; doc.surface = validated.surface; doc.operation = operation; doc.inputId = inputId;
  }, ctx);
  return validated;
}

export function nutritionExtension(nativeTool, uuid, presented = async () => {}, currentInput = async () => null) {
  const names = new Set(['nutrition_view', 'filter_nutrition', 'prepare_meal_copy']);
  const registered = (name, description, parameters, patch) => defineTool({ name, description,
    parameters: Type.Object({ ...parameters, revision: Type.Optional(Type.Integer({ description: 'Host metadata; omit.' })), responseMode: Type.Optional(Type.String({ enum: ['view', 'answer'], description: 'Host response metadata; omit.' })) }, { additionalProperties: false }),
    replay: 'safe',
    execute: async (args, api, ctx) => {
      const operation = await api.memo('nutrition-operation', uuid(), ctx);
      const readOnly = name === 'nutrition_view' && args.responseMode === 'answer';
      const result = await updateNutrition(api, api.conversationId, { ...patch(args), revision: args.revision }, operation, nativeTool, ctx, {readOnly, inputId: await currentInput(api, ctx)});
      if (!readOnly) await presented(api, ctx);
      return { output: [{ type: 'text', text: JSON.stringify(result) }], ...(!readOnly ? {control: { terminate: true }} : {}) };
    },
  });
  return defineExtension({ name: 'banana-nutrition', hooks: [hook(GenerationTask, {
    beforeRequest: async ({ messages }, api, ctx) => {
      const text = getCurrentSystemMessage(messages)?.sections?.['nutrition-view'] ?? '';
      const match = text.match(/^(?:<nutrition-view>\n)?Revision (\d+)\n/);
      if (match) await api.memo('banana-nutrition-basis', Number(match[1]), ctx);
    },
    afterResponse: async (message, api, ctx) => {
      const revision = await api.memo('banana-nutrition-basis', ctx);
      for (const part of message.content) if (part.type === 'toolCall' && names.has(part.name)) {
        if (!Number.isSafeInteger(revision)) throw new Error('Nutrition request has no captured view revision.');
        part.arguments = { ...part.arguments, revision };
      }
    },
  })], sections: [section('nutrition-view', async ({ read, conversationId }, ctx) => {
    const doc = await read.snapshot(NutritionDoc, conversationId, ctx);
    let active = doc?.surface ?? { revision: 0 };
    if (doc?.surface) {
      try { active = await nativeTool({ name: 'nutrition_view', arguments: doc.surface }, ctx.abortSignal); }
      catch { active = { surface: doc.surface, dataUnavailable: true }; }
    }
    return `Revision ${doc?.revision ?? 0}\nCurrent native nutrition view: ` + JSON.stringify(active) +
      '. nutrition_view opens charts or searches food names. filter_nutrition changes only requested filters. ' +
      'prepare_meal_copy creates a review draft using an actual visible meal ID; it never saves. ' +
      'For repeat/add-again meal requests, use prepare_meal_copy directly with the most recent matching visible meal ID; do not search again when matching IDs are already listed. Default to today unless another date is requested. ' +
      'The host manages revision metadata. Dates are local and inclusive; period computes relative ranges natively. ' +
      'Explicit view actions end the turn because the native interface is the answer. Nutrition questions read facts without opening a chart and must continue to a written answer. Calories and macros are recorded. read_nutrients estimates choline, fiber, vitamins and minerals from USDA-linked foods with logged weights. It reports missing data explicitly and never opens a chart. Use it before answering micronutrient questions. Cite its source/reference links. Estimates, missing foods/days and supplements cannot establish complete intake or a diagnosis; do not infer age, sex or pregnancy/lactation status or select a personal target without that context. If sampleData is true, describe sample results rather than personal intake. Do not prescribe supplements or doses from an incomplete log. Never substitute a different nutrient. For explanations, use current native facts and reply directly. Missing prior logs cannot establish equal or zero intake. Never claim a meal draft exists unless the result contains draftMealID and draftDate.';
  })], tools: [
    defineTool({ name: 'read_nutrients',
      description: 'Read USDA-based estimates of a named nutrient from logged foods and their portion weights. Use the nutrient phrase verbatim from the current request. Includes coverage, missing items/days and sources; never changes a chart or saves a record.',
      parameters: Type.Object({ nutrient: Type.String({description: 'The nutrient phrase verbatim from the request; native validation limits length to 80 characters.'}),
        period: Type.Optional(Type.String({enum: ['this_week', 'this_month', 'last_month', 'last_7_days', 'last_30_days'], description: 'Only use a period requested by the person. Omit for the default last seven days.'})),
        start: Type.Optional(Type.String()), end: Type.Optional(Type.String()) }, {additionalProperties: false}),
      replay: 'safe', execute: async (args, api, ctx) => {
        const result = await nativeTool({name: 'read_nutrients', arguments: args}, ctx.abortSignal);
        return {output: [{type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result)}]};
      },
    }),
    registered('nutrition_view', 'Show a nutrition chart or find logged meals. Nutrients use metric; foodName is only an explicitly named food (e.g. yogurt), never a nutrient. Omitted fields keep the current view.',
      { metric: fields.metric, period: fields.period, start: fields.start, end: fields.end, foodName: fields.search },
      (args) => ({ ...args, ...(Object.hasOwn(args, 'foodName') ? { search: args.foodName } : {}) })),
    registered('filter_nutrition', 'Update the current chart filters. Choose only changes requested by the person. Use compare_previous to compare the preceding period.',
      { changes: Type.Array(Type.String({ enum: ['weekdays_only', 'all_days', 'compare_previous', 'stop_comparing'] })) },
      (args) => {
        if (!args.changes.length || args.changes.length > 2 ||
            (args.changes.includes('weekdays_only') && args.changes.includes('all_days')) ||
            (args.changes.includes('compare_previous') && args.changes.includes('stop_comparing'))) throw new Error('Choose one change for each filter.');
        const patch = {};
        for (const change of args.changes) {
          if (change === 'weekdays_only' || change === 'all_days') patch.weekdaysOnly = change === 'weekdays_only';
          else patch.compare = change === 'compare_previous';
        }
        return patch;
      }),
    registered('prepare_meal_copy', 'Prepare a copy of an existing logged meal for native review. For repeat/add-again requests with no date, use today. Use an actual mealID from current native data. This opens a draft and does not save or change chart filters.',
      { mealID: Type.String(), day: Type.String({ enum: ['today', 'tomorrow', 'date'], description: 'Use today when the person asks to repeat a meal without specifying a date. Use tomorrow or date only when requested.' }), date: Type.Optional(Type.String({ description: 'YYYY-MM-DD, required only when day is date.' })) },
      (args) => ({ draftMealID: args.mealID, draftRelativeDay: args.day, draftDate: args.date ?? null })),
  ] });
}
