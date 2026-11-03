import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { Harness } from '@earendil-works/pi-durable';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';

/** Platform lifetime only. Pi retains all scheduling, checkpoint and recovery decisions. */
export class ApplePiSession {
  harness;
  tail = Promise.resolve();
  wakeTimer;
  acceptingWake = false;
  constructor(options, { now = Date.now, publishWake = (wake) => {
    const result = JSON.parse(nativePublishWake(JSON.stringify(wake)));
    if (!result.ok) throw new Error(result.error.message);
  } } = {}) {
    this.options = options;
    this.now = now;
    this.publishWake = publishWake;
  }
  transition(operation) {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {});
    return result;
  }
  wake(wake) {
    if (!this.acceptingWake) return;
    this.publishWake(wake);
    clearTimeout(this.wakeTimer);
    this.wakeTimer = undefined;
    if (wake.at !== undefined && this.harness) {
      // This timer only delivers Pi's next foreground wake. It owns no task state.
      this.wakeTimer = setTimeout(() => {
        this.wakeTimer = undefined;
        if (this.acceptingWake && this.harness) {
          this.wake(this.harness.wake()); // Re-arm if an early/clamped timer fired.
          this.harness.resume();
        }
      }, Math.min(2147483647, Math.max(0, wake.at - this.now())));
    }
  }
  activate() {
    return this.transition(async () => {
      if (this.harness) return this.harness;
      this.acceptingWake = true;
      let harness, storage, database;
      try {
        database = new NativeDatabase();
        storage = await SqliteStorage.open(database);
        harness = await Harness.open(storage, { ...this.options, now: this.now,
          onWake: (wake) => this.wake(wake),
          setTimer: (callback, delay, { background }) => {
            if (background) return undefined;
            const id = setTimeout(callback, delay);
            return () => clearTimeout(id);
          },
        }, BACKGROUND_CONTEXT);
        this.harness = harness;
        this.wake(harness.wake());
        harness.resume();
        return harness;
      } catch (error) {
        this.acceptingWake = false;
        clearTimeout(this.wakeTimer);
        this.harness = undefined;
        if (harness) await harness.close(BACKGROUND_CONTEXT);
        else if (storage) await storage.close(BACKGROUND_CONTEXT);
        else if (database) await database.close();
        throw error;
      }
    });
  }
  deactivate() {
    return this.transition(async () => {
      const harness = this.harness;
      if (!harness) return;
      this.acceptingWake = false;
      clearTimeout(this.wakeTimer);
      this.wakeTimer = undefined;
      try { this.publishWake(harness.wake()); }
      finally {
        try { await harness.close(BACKGROUND_CONTEXT); }
        finally { this.harness = undefined; }
      }
    });
  }
}
