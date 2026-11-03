import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { Harness, ReadOnlySession, createRegistry, defineExtension } from '@earendil-works/pi-durable';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';
import { ApplePiSession } from './apple-session.js';
import { createLifecycleSleeper } from './lifecycle-proof.js';

function assert(value, message) { if (!value) throw new Error(message); }
const resources = () => JSON.parse(nativeHostResources()).value;

export async function runHandoffProof() {
  let armCalls = 0, deliverCalls = 0, wakeCalls = 0;
  const Sleeper = createLifecycleSleeper(() => armCalls++, () => deliverCalls++);
  const registry = createRegistry();
  registry.install(defineExtension({ name: 'banana-handoff-proof', tasks: [Sleeper] }));
  const options = { models: createModels(), registry };
  const viewer = nativeMode === 'handoff-viewer' || nativeMode === 'handoff-completed';
  const session = viewer ? undefined : new ApplePiSession(options);
  const harness = viewer
    ? await Harness.open(await SqliteStorage.open(new NativeDatabase()), { ...options, readOnly: true, onWake: () => wakeCalls++ }, context)
    : await session.activate();
  const close = () => viewer ? harness.close(context) : session.deactivate();
  try {
    const root = await harness.root(context);
    const tasks = await root.commit((tx) => tx.scanTasks({ kind: Sleeper.definition.name }, 10), context);
    let task;
    if (nativeMode === 'handoff-first') {
      assert(tasks.items.length === 0, 'Handoff source must start empty');
      const id = await root.commit((tx) => tx.createTask(Sleeper, { until: Date.now() + 10000 }, { ownership: { kind: 'conversation' } }), context);
      task = await new Promise((resolve, reject) => {
        let stop;
        const inspect = () => harness.getTask(id, context).then((record) => {
          if (record.state.status === 'sleeping') { stop?.(); resolve(record); }
        }, (error) => { stop?.(); reject(error); });
        stop = harness.subscribeCommits(() => { void inspect(); });
        void inspect();
      });
      assert(armCalls === 1 && deliverCalls === 0, 'Source must close before delivery');
    } else {
      assert(tasks.items.length === 1, 'Transferred database must contain exactly one sleeper');
      task = tasks.items[0];
      if (viewer) {
        const expected = nativeMode === 'handoff-viewer' ? 'sleeping' : 'terminal';
        assert(task.state.status === expected, `Viewer expected ${expected}`);
        const before = JSON.stringify(task);
        let resumeRejected = false, writeRejected = false;
        try { harness.resume(); } catch (error) { resumeRejected = error instanceof ReadOnlySession; }
        try {
          await root.commit((tx) => tx.createTask(Sleeper, { until: Date.now() }, { ownership: { kind: 'conversation' } }), context);
        } catch (error) { writeRejected = error instanceof ReadOnlySession; }
        assert(resumeRejected && writeRejected, 'Read-only viewer must reject scheduling and writes');
        assert(JSON.stringify(await harness.getTask(task.id, context)) === before, 'Viewer must preserve the task record');
        assert(armCalls === 0 && deliverCalls === 0 && wakeCalls === 0 && !harness.wake().active, 'Viewer must execute no work');
      } else {
        task = await harness.waitForTask(task.id, context);
        assert(task.state.outcome.status === 'completed', 'Destination must complete the transferred task');
        assert(armCalls === 0 && deliverCalls === 1, 'Destination must resume only delivery');
        assert(task.state.outcome.result.wokeAt >= task.input.until, 'Cross-device delivery cannot precede the epoch deadline');
      }
    }
    await close();
    const nativeResources = resources();
    assert(nativeResources.databases === 0 && nativeResources.timers === 0 && nativeResources.modelRequests === 0, 'Source/destination must release all Pi native resources before transfer');
    return { mode: nativeMode, passed: true, task, armCalls, deliverCalls, wakeCalls, readOnly: viewer, nativeResources, clock: 'real epoch clock on each host' };
  } finally { await close(); }
}
