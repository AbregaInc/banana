import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { Harness, createRegistry } from '@earendil-works/pi-durable';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxProvider, fauxAssistantMessage, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';
import { NutritionDoc, updateNutrition, nutritionExtension } from './nutrition.js';

export async function runNutritionConformance() {
  const results = [];
  const check = (condition, name) => { if (!condition) throw new Error(name); results.push(name); };
  const models = createModels(), registry = createRegistry();
  const open = async () => Harness.open(await SqliteStorage.open(new NativeDatabase()), { models, registry }, ctx);
  let harness = await open();
  try {
    const conversation = await harness.root(ctx);
    const id = conversation.id;
    const native = async ({ arguments: surface }) => ({ surface, summary: { loggedDays: 2 } });
    const extension = nutritionExtension(native, () => 'schema-check');
    check(extension.tools.every((tool) => JSON.parse(nativeModelValidateSchema(JSON.stringify(tool.parameters))).ok), 'Actual extension schema translates to Apple guided generation');
    await updateNutrition(harness, id, { revision: 0, metric: 'protein', start: '2026-10-01', end: '2026-10-24' }, 'first', native, ctx);
    let doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.revision === 1 && doc.surface.metric === 'protein', 'Pi commits initial native surface');
    await updateNutrition(harness, id, { revision: 1, selectedDay: '2026-10-22' }, 'select', native, ctx);
    await updateNutrition(harness, id, { revision: 2, weekdaysOnly: true }, 'filter', native, ctx);
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.surface.selectedDay === null && doc.surface.weekdaysOnly && doc.surface.start === '2026-10-01', 'Filter patch preserves query and clears stale selection');
    let rejected = false;
    try { await updateNutrition(harness, id, { revision: 1, compare: true }, 'stale', native, ctx); } catch { rejected = true; }
    check(rejected, 'Old revisions cannot overwrite touch edits');
    let release, began;
    const started = new Promise((resolve) => { began = resolve; });
    const pending = updateNutrition(harness, id, { revision: 3, metric: 'fat' }, 'late', async (request) => {
      began(); await new Promise((resolve) => { release = resolve; }); return native(request);
    }, ctx).then(() => false, () => true);
    await started;
    await updateNutrition(harness, id, { revision: 3, compare: true }, 'touch', native, ctx);
    release(); check(await pending, 'Late inference loses compare-and-swap race');
    await updateNutrition(harness, id, { revision: 3, compare: true }, 'touch', native, ctx);
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.revision === 4 && doc.surface.metric === 'protein', 'Acknowledgement retry does not apply twice');
    const prompt = await extension.sections[0].render({ read: harness, conversationId: id }, ctx);
    check(prompt.includes('loggedDays') && prompt.includes('"revision":4'), 'Prompt section includes current native data with view revision');
    await harness.close(ctx); harness = await open();
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.revision === 4 && doc.surface.compare, 'SQLite cold reopen restores exact surface');
    const other = await harness.createConversation({ ownership: { kind: 'ownerless' } }, ctx);
    check(!await harness.snapshot(NutritionDoc, other.id, ctx), 'New conversation has no inherited active view');
    let failed = false;
    try { await updateNutrition(harness, id, { revision: 4, metric: 'fat' }, 'bad', async () => { throw new Error('Invalid native query'); }, ctx); } catch { failed = true; }
    check(failed && (await harness.snapshot(NutritionDoc, id, ctx)).revision === 4, 'Native validation failure leaves committed view unchanged');
    registry.install(extension);
    const faux = fauxProvider(); models.setProvider(faux.provider);
    const restored = await harness.conversation(id, ctx);
    await restored.configure({ model: { provider: 'faux', modelId: 'faux-1' } }, ctx);
    let modelCalls = 0;
    faux.setResponses([
      () => { modelCalls++; return fauxAssistantMessage([fauxToolCall('filter_nutrition', { revision: 999, changes: ['weekdays_only'] })], { stopReason: 'toolUse' }); },
      () => { modelCalls++; return fauxAssistantMessage('Updated the view.'); },
    ]);
    await (await restored.submit({ type: 'input', content: 'Only weekdays', requestId: 'host-bound-revision' }, ctx)).wait(ctx);
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.revision === 5 && doc.surface.weekdaysOnly, 'Public generation hooks bind execution metadata instead of trusting model revision');
    check(modelCalls === 1, 'Pi terminate control completes a native view without a second generation');
    const startedLate = new Promise((resolve) => { began = resolve; });
    faux.setResponses([
      async () => { began(); await new Promise((resolve) => { release = resolve; });
        return fauxAssistantMessage([fauxToolCall('filter_nutrition', { changes: ['all_days'] })], { stopReason: 'toolUse' }); },
      fauxAssistantMessage('The view changed.'),
    ]);
    const late = await restored.submit({ type: 'input', content: 'Include weekends', requestId: 'late-model-view' }, ctx);
    await startedLate;
    await updateNutrition(harness, id, { revision: 5, compare: false }, 'newer-touch', native, ctx);
    release(); await late.wait(ctx);
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.revision === 6 && doc.surface.weekdaysOnly && !doc.surface.compare, 'Captured model basis cannot overwrite a touch made during inference');
    const draftID = 'a3a38a30-85ce-4bdb-8740-205576446310';
    await updateNutrition(harness, id, { revision: 6, draftMealID: 'meal-source', draftDate: '2026-10-25' }, draftID, native, ctx);
    doc = await harness.snapshot(NutritionDoc, id, ctx);
    check(doc.surface.draftID === draftID, 'Meal draft save identity is committed by Pi before review');
    await updateNutrition(harness, id, { revision: 7, draftMealID: null, draftDate: null }, 'dismiss', native, ctx);
    check(!(await harness.snapshot(NutritionDoc, id, ctx)).surface.draftID, 'Dismissing a draft removes its active save identity');
    return { passed: true, results };
  } finally { await harness.close(ctx); }
}
