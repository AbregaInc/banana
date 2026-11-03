import { expect } from 'chai';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { createRegistry, defineExtension, defineTask } from '@earendil-works/pi-durable';
import { ApplePiSession } from './apple-session.js';
import { requestNativeGeneration } from './apple-provider.js';

export async function runLifecycleConformance() {
  const results = [];
  const resources = () => JSON.parse(nativeHostResources()).value;
  const check = async (name, run) => {
    try { await run(); results.push({ name, passed: true }); }
    catch (error) { results.push({ name, passed: false, error: String(error), stack: error.stack }); }
    nativeLog(`${results.at(-1).passed ? 'PASS' : 'FAIL'} ${name}`);
  };
  const options = () => ({ models: createModels(), registry: createRegistry() });
  await check('duplicate activation shares one harness and repeated close is harmless', async () => {
    const session = new ApplePiSession(options());
    try {
      const [first, second] = await Promise.all([session.activate(), session.activate()]);
      expect(first).to.equal(second);
      expect(resources().databases).to.equal(1);
    } finally { await session.deactivate(); await session.deactivate(); }
    expect(resources().databases).to.equal(0);
  });
  await check('rapid close/open transitions join old work before opening the next harness', async () => {
    const session = new ApplePiSession(options());
    try {
      const first = await session.activate();
      const closing = session.deactivate(), reopening = session.activate();
      await closing;
      const second = await reopening;
      expect(second).not.to.equal(first);
      expect(resources().databases).to.equal(1);
    } finally { await session.deactivate(); }
    expect(resources().databases).to.equal(0);
  });
  await check('failed wake publication closes the partially opened backend', async () => {
    const session = new ApplePiSession(options(), { publishWake: () => { throw new Error('wake write probe'); } });
    let rejected = false;
    try { await session.activate(); } catch (error) { rejected = true; expect(String(error)).to.include('wake write probe'); }
    expect(rejected).to.equal(true);
    expect(resources().databases).to.equal(0);
    await session.deactivate();
  });
  await check('close cancels native model work; reopen resumes the persisted task checkpoint', async () => {
    let started, runs = 0, aborted = 0, hold = true;
    const ready = new Promise((resolve) => { started = resolve; });
    const Work = defineTask({ name: 'banana.lifecycle-cancellation', version: 1, initial: () => ({ phase: 'run' }), phases: {
      run: async (_task, runtime, ctx) => {
        runs++;
        if (hold) {
          const generation = requestNativeGeneration({ instructions: '', tools: [], messages: [{ role: 'user', text: 'Reply hello.' }] }, runtime.signal);
          expect(resources().modelRequests).to.equal(1);
          started();
          try { await generation; } catch (error) { if (runtime.signal.aborted) aborted++; throw error; }
        }
        await runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: 'resumed' } }), ctx);
      },
    }, abort: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx) });
    const settings = options();
    settings.registry.install(defineExtension({ name: 'lifecycle-cancellation', tasks: [Work] }));
    const session = new ApplePiSession(settings);
    try {
      let harness = await session.activate();
      const root = await harness.root(context);
      const id = await root.commit((tx) => tx.createTask(Work, null, { ownership: { kind: 'conversation' } }), context);
      await ready;
      await session.deactivate();
      expect(aborted).to.equal(1);
      expect(resources().modelRequests).to.equal(0);
      expect(resources().databases).to.equal(0);
      hold = false;
      harness = await session.activate();
      const task = await harness.waitForTask(id, context);
      expect(task.state.outcome).to.deep.equal({ status: 'completed', result: 'resumed' });
      expect(runs).to.equal(2);
    } finally { await session.deactivate(); }
  });
  await check('foreground wake delivers a sleeping task at its real deadline', async () => {
    const Sleeper = defineTask({ name: 'banana.lifecycle-foreground-timer', version: 1, initial: () => ({ phase: 'arm' }), phases: {
      arm: (task, runtime, ctx) => runtime.sleepUntil(task.input.until, { phase: 'deliver' }, ctx),
      deliver: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: runtime.now() } }), ctx),
    }, abort: (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx) });
    const settings = options();
    settings.registry.install(defineExtension({ name: 'lifecycle-timer', tasks: [Sleeper] }));
    const session = new ApplePiSession(settings);
    try {
      const harness = await session.activate(), root = await harness.root(context);
      const until = Date.now() + 25;
      const id = await root.commit((tx) => tx.createTask(Sleeper, { until }, { ownership: { kind: 'conversation' } }), context);
      const task = await harness.waitForTask(id, context);
      expect(task.state.outcome.status).to.equal('completed');
      expect(task.state.outcome.result).to.be.at.least(until);
    } finally { await session.deactivate(); }
    expect(resources()).to.deep.equal({ databases: 0, timers: 0, modelRequests: 0 });
  });
  const failed = results.filter((result) => !result.passed);
  return { mode: nativeMode, passed: failed.length === 0, total: results.length, failed, results };
}
