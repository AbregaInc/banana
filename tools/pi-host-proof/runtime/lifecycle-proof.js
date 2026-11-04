import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { createRegistry, defineExtension, defineTask } from '@earendil-works/pi-durable';
import { ApplePiSession } from './apple-session.js';

function assert(value, message) { if (!value) throw new Error(message); }
function nativeResult(raw) { const result = JSON.parse(raw); if (!result.ok) throw new Error(result.error.message); return result.value; }

export function createLifecycleSleeper(onArm = () => {}, onDeliver = () => {}) {
  return defineTask({ name: 'banana.lifecycle-sleeper', version: 1, initial: () => ({ phase: 'arm' }), phases: {
    arm: (task, runtime, ctx) => { onArm(); return runtime.sleepUntil(task.input.until, { phase: 'deliver' }, ctx); },
    deliver: (_task, runtime, ctx) => {
      onDeliver();
      return runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: { wokeAt: runtime.now() } } }), ctx);
    },
  }, abort: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx) });
}

export async function runLifecycleProof() {
  const live = nativeMode === 'lifecycle-live', reopening = nativeMode === 'lifecycle-reopen';
  let clock = Date.now(), armCalls = 0, deliverCalls = 0;
  const now = live ? Date.now : () => clock;
  const Sleeper = createLifecycleSleeper(() => armCalls++, () => deliverCalls++);
  const registry = createRegistry();
  registry.install(defineExtension({ name: 'banana-lifecycle', tasks: [Sleeper] }));
  const errors = [], wakes = [];
  const session = new ApplePiSession({ models: createModels(), registry,
    onReport: (error, info) => errors.push({ error: String(error), info }),
  }, { now, publishWake: (wake) => {
    nativeResult(nativePublishWake(JSON.stringify(wake)));
    wakes.push(wake);
  } });
  let harness = await session.activate();
  const root = await harness.root(context);
  const records = await root.commit((tx) => tx.scanTasks({ kind: Sleeper.definition.name }, 10), context);
  let id = records.items[0]?.id;
  const recoveredLive = live && records.items.length > 0;
  if (reopening || recoveredLive) {
    assert(records.items.length === 1, 'Must find exactly one persisted sleeper');
    const stored = await harness.getTask(id, context);
    if (reopening) {
      assert(stored.state.status === 'sleeping', 'Reopen must find the stored sleeping checkpoint');
      clock = stored.input.until;
    }
  } else {
    assert(records.items.length === 0, 'New lifecycle proof requires an empty database');
    id = await root.commit((tx) => tx.createTask(Sleeper, { until: now() + (live ? 10000 : 60000) }, { ownership: { kind: 'conversation' } }), context);
  }
  let unlisten;
  async function waitForStatus(expected) {
    const current = await harness.getTask(id, context);
    if (current.state.status === expected) return current;
    return new Promise((resolve, reject) => {
      let checking = false, again = false;
      const inspect = async () => {
        if (checking) { again = true; return; }
        checking = true;
        try {
          do {
            again = false;
            const task = await harness.getTask(id, context);
            if (task.state.status === expected) { unlisten?.(); resolve(task); return; }
          } while (again);
        } catch (error) { unlisten?.(); reject(error); }
        finally { checking = false; }
      };
      unlisten = harness.subscribeCommits(() => { void inspect(); });
      void inspect();
    });
  }
  function snapshot(phase, task) {
    nativeResult(nativeLifecycleSnapshot(JSON.stringify({ mode: nativeMode, phase, task, armCalls, deliverCalls, wakes, errors })));
  }
  try {
    if (reopening || recoveredLive) {
      harness.resume();
      const task = await waitForStatus('terminal');
      assert(task.state.outcome.status === 'completed', 'Reopened sleeper must complete');
      assert(armCalls === 0 && (deliverCalls === 1 || (recoveredLive && deliverCalls === 0)), 'Resume must run only uncompleted delivery');
      assert(task.state.outcome.result.wokeAt >= task.input.until, 'Task must not deliver early');
      return { mode: nativeMode, passed: errors.length === 0, armCalls, deliverCalls, task, wakes, errors,
        clock: recoveredLive ? 'real epoch clock; runtime recreated after expiration' : 'controlled epoch clock advanced to stored deadline' };
    }
    const sleeping = await waitForStatus('sleeping');
    assert(harness.wake().at === sleeping.input.until, 'Pi wake must equal the stored sleep deadline');
    if (!live) {
      await session.deactivate();
      const hint = nativeResult(nativeReadWake());
      assert(hint.at === sleeping.input.until, 'Closing must preserve the wake hint');
      snapshot('paused', sleeping);
      return { mode: nativeMode, passed: errors.length === 0 && armCalls === 1 && deliverCalls === 0,
        armCalls, deliverCalls, task: sleeping, hint, wakes, errors };
    }
    snapshot('sleeping', sleeping);
    return await new Promise((resolve, reject) => {
      let foregroundTail = Promise.resolve();
      globalThis.piSetForeground = (active, done) => {
        const transition = async () => {
          unlisten?.();
          if (!active) {
            await session.deactivate();
            snapshot('paused', sleeping);
            done('', true);
            return;
          }
          harness = await session.activate();
          const task = await waitForStatus('terminal');
          const passed = errors.length === 0 && armCalls === 1 && deliverCalls === 1
            && task.state.outcome.status === 'completed' && task.state.outcome.result.wokeAt >= task.input.until;
          snapshot('completed', task);
          done('', true);
          resolve({ mode: nativeMode, passed, armCalls, deliverCalls, task, wakes, errors, clock: 'real epoch clock; actual UIKit background/foreground callbacks' });
        };
        foregroundTail = foregroundTail.then(transition).catch((error) => { done(String(error), false); reject(error); });
      };
    });
  } finally {
    unlisten?.();
    globalThis.piSetForeground = undefined;
    await session.deactivate();
  }
}
