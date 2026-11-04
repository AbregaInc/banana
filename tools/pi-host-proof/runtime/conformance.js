import { expect } from 'chai';
import { createStorageConformance } from '@earendil-works/pi-durable/testing';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';

const assertions = {
  ok: (value, message) => expect(value, message).to.be.ok,
  strictEqual: (actual, expected) => expect(actual).to.equal(expected),
  deepEqual: (actual, expected) => expect(actual).to.deep.equal(expected),
  greaterThan: (actual, expected) => expect(actual).to.be.greaterThan(expected),
  partialDeepEqual(actual, expected) {
    for (const [key, value] of Object.entries(expected)) {
      if (value && typeof value === 'object') this.partialDeepEqual(actual[key], value);
      else expect(actual[key]).to.equal(value);
    }
  },
  async rejects(operation, text) {
    try { await operation; } catch (error) { expect(String(error)).to.include(text); return; }
    throw new Error(`Expected rejection containing ${text}`);
  },
};

export async function runHostConformance() {
  const results = [];
  async function check(name, run) {
    try { await run(); results.push({ name, passed: true }); }
    catch (error) { results.push({ name, passed: false, error: String(error), stack: error.stack }); }
    nativeLog(`${results.at(-1).passed ? 'PASS' : 'FAIL'} ${name}`);
  }
  await check('UTF-8 streams preserve every split of an emoji', () => {
    const bytes = new TextEncoder().encode('A🍌B');
    for (let split = 0; split <= bytes.length; split++) {
      const decoder = new TextDecoder();
      expect(decoder.decode(bytes.subarray(0, split), { stream: true }) + decoder.decode(bytes.subarray(split))).to.equal('A🍌B');
    }
  });
  await check('UTF-8 fatal decoding and BOM policy', () => {
    expect(() => new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.of(0xf0, 0x90, 0x80))).to.throw();
    const bytes = Uint8Array.of(0xef, 0xbb, 0xbf, 0x41);
    expect(new TextDecoder().decode(bytes)).to.equal('A');
    expect(new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes)).to.equal('\uFEFFA');
    const decoder = new TextDecoder();
    expect(decoder.decode(Uint8Array.of(0xf0), { stream: true }) + decoder.decode()).to.equal('\uFFFD');
  });
  await check('TextEncoder preserves character boundaries and view offsets', () => {
    const bytes = new Uint8Array(6).fill(99);
    expect(new TextEncoder().encodeInto('🍌x', bytes.subarray(1, 4))).to.deep.equal({ read: 0, written: 0 });
    expect(Array.from(bytes)).to.deep.equal([99, 99, 99, 99, 99, 99]);
    expect(new TextEncoder().encodeInto('🍌x', bytes.subarray(1, 5))).to.deep.equal({ read: 2, written: 4 });
    expect(new TextDecoder().decode(new DataView(bytes.buffer, 1, 4))).to.equal('🍌');
    expect(new TextDecoder().decode(new TextEncoder().encode('\uD800'))).to.equal('\uFFFD');
  });
  await check('structuredClone preserves cycles, maps, dates, undefined and shared buffers', () => {
    const bytes = Uint8Array.of(1, 2);
    const source = { missing: undefined, nan: NaN, date: new Date(123), map: new Map([['a', 1]]), bytes, view: new Uint8Array(bytes.buffer) };
    source.self = source;
    const copy = structuredClone(source);
    expect(copy).not.to.equal(source);
    expect(copy.self).to.equal(copy);
    expect(Object.hasOwn(copy, 'missing')).to.equal(true);
    expect(Number.isNaN(copy.nan)).to.equal(true);
    expect(copy.date.getTime()).to.equal(123);
    expect(copy.map.get('a')).to.equal(1);
    expect(copy.bytes.buffer).to.equal(copy.view.buffer);
    copy.bytes[0] = 9;
    expect(source.bytes[0]).to.equal(1);
    expect(() => structuredClone({ fn() {} })).to.throw(DOMException).with.property('name', 'DataCloneError');
  });
  await check('WHATWG URL resolution, IDNA, mutable search params and validation', () => {
    const url = new URL('../a b?q=1#x', 'https://BÜCHER.example/one/two');
    expect(url.href).to.equal('https://xn--bcher-kva.example/a%20b?q=1#x');
    url.searchParams.set('q', 'hello world');
    expect(url.search).to.equal('?q=hello+world');
    url.hash = 'next';
    expect(url.hash).to.equal('#next');
    expect(URL.canParse('https://example.com')).to.equal(true);
    expect(URL.canParse('not absolute')).to.equal(false);
  });
  await check('abort is synchronous, preserves first reason and dispatches once', () => {
    const controller = new AbortController();
    const reason = new Error('first');
    let calls = 0;
    const listener = (event) => { expect(event.target).to.equal(controller.signal); expect(controller.signal.reason).to.equal(reason); calls++; };
    controller.signal.addEventListener('abort', listener, { once: true });
    controller.signal.addEventListener('abort', listener, { once: true });
    controller.abort(reason);
    controller.abort(new Error('second'));
    expect(calls).to.equal(1);
    expect(() => controller.signal.throwIfAborted()).to.throw(reason);
    expect(AbortSignal.abort().reason).to.be.instanceOf(DOMException).with.property('name', 'AbortError');
  });
  await check('AbortSignal.any handles already-aborted and later-aborted sources', () => {
    const first = new AbortController(), second = new AbortController();
    const combined = AbortSignal.any([first.signal, second.signal]);
    second.abort('chosen');
    first.abort('too late');
    expect(combined.reason).to.equal('chosen');
    expect(AbortSignal.any([first.signal, second.signal]).reason).to.equal('too late');
    expect(() => AbortSignal.any([{}])).to.throw(TypeError);
  });
  await check('AbortSignal.timeout dispatches TimeoutError', async () => {
    const signal = AbortSignal.timeout(0);
    await new Promise((resolve) => signal.addEventListener('abort', resolve, { once: true }));
    expect(signal.reason.name).to.equal('TimeoutError');
    expect(() => AbortSignal.timeout(-1)).to.throw(RangeError);
  });
  await check('native timers carry arguments, cancel, and follow microtasks', async () => {
    const order = [];
    const cancelled = setTimeout(() => order.push('cancelled'), 0);
    clearTimeout(cancelled);
    queueMicrotask(() => order.push('microtask'));
    Promise.resolve().then(() => order.push('promise'));
    await new Promise((resolve) => setTimeout((value) => { order.push(value); resolve(); }, 0, 'timer'));
    expect(order).to.deep.equal(['microtask', 'promise', 'timer']);
  });
  await check('performance clock is independent of wall-clock adjustment', () => {
    const original = Date.now;
    try { const before = performance.now(); Date.now = () => -1000000; expect(performance.now()).to.be.at.least(before); }
    finally { Date.now = original; }
  });
  await check('throwing microtasks reach the native error reporter', async () => {
    const before = JSON.parse(nativeReportedErrors()).length;
    queueMicrotask(() => { throw new Error('intentional-host-microtask-probe'); });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const errors = JSON.parse(nativeReportedErrors());
    expect(errors.length).to.equal(before + 1);
    expect(errors.at(-1)).to.include('intentional-host-microtask-probe');
  });
  await check('crypto validates integer views and 65536-byte quota', () => {
    const buffer = new Uint8Array(20).fill(99), view = new Uint8Array(buffer.buffer, 2, 16);
    expect(crypto.getRandomValues(view)).to.equal(view);
    expect(Array.from(buffer.subarray(0, 2))).to.deep.equal([99, 99]);
    expect(Array.from(buffer.subarray(18))).to.deep.equal([99, 99]);
    expect(() => crypto.getRandomValues(new Float64Array(1))).to.throw(DOMException).with.property('name', 'TypeMismatchError');
    expect(() => crypto.getRandomValues(new Uint8Array(65537))).to.throw(DOMException).with.property('name', 'QuotaExceededError');
  });
  await check('SQLite binding preserves NUL, Unicode, zero-length blobs, integers and null', async () => {
    const db = new NativeDatabase(':memory:');
    try {
      await db.exec('CREATE TABLE values_test (text_value TEXT, bytes BLOB, n INTEGER, empty BLOB, nothing_value TEXT)');
      await db.run('INSERT INTO values_test VALUES (?, ?, ?, ?, ?)', 'a\0🍌z', Uint8Array.of(0, 255, 1), 9007199254740991n, new Uint8Array(), null);
      const row = await db.get('SELECT * FROM values_test');
      expect(row.text_value).to.equal('a\0🍌z');
      expect(Array.from(row.bytes)).to.deep.equal([0, 255, 1]);
      expect(row.n).to.equal(Number.MAX_SAFE_INTEGER);
      expect(row.empty).to.be.instanceOf(Uint8Array).with.length(0);
      expect(row.nothing_value).to.equal(null);
      await assertions.rejects(db.run('INSERT INTO values_test (n) VALUES (?)', 9223372036854775808n), '64-bit');
      await assertions.rejects(db.run('INSERT INTO values_test (n) VALUES (?)', 9007199254740992), 'Unsafe');
    } finally { await db.close(); }
  });
  await check('SQLite rollback, revoked handles and transaction isolation', async () => {
    const db = new NativeDatabase(':memory:');
    try {
      await db.exec('CREATE TABLE items (value TEXT)');
      let handle;
      await assertions.rejects(db.transaction(async (tx) => { handle = tx; await tx.run('INSERT INTO items VALUES (?)', 'rollback'); throw new Error('abort transaction'); }), 'abort transaction');
      expect((await db.all('SELECT * FROM items')).length).to.equal(0);
      await assertions.rejects(handle.all('SELECT * FROM items'), 'no longer active');
      let release, started;
      const startedPromise = new Promise((resolve) => { started = resolve; });
      const gate = new Promise((resolve) => { release = resolve; });
      const transaction = db.transaction(async (tx) => { await tx.run('INSERT INTO items VALUES (?)', 'first'); started(); await gate; await tx.run('INSERT INTO items VALUES (?)', 'second'); });
      await startedPromise;
      const outside = db.run('INSERT INTO items VALUES (?)', 'third');
      release();
      await Promise.all([transaction, outside]);
      expect((await db.all('SELECT * FROM items ORDER BY rowid')).map((row) => row.value)).to.deep.equal(['first', 'second', 'third']);
    } finally { await db.close(); }
    await assertions.rejects(db.all('SELECT 1'), 'closed');
  });
  await check('SQLite constraint failures roll back earlier statements', async () => {
    const db = new NativeDatabase(':memory:');
    try {
      await db.exec('CREATE TABLE unique_items (id INTEGER PRIMARY KEY)');
      await assertions.rejects(db.transaction(async (tx) => {
        await tx.run('INSERT INTO unique_items VALUES (?)', 1);
        await tx.run('INSERT INTO unique_items VALUES (?)', 1);
      }), 'UNIQUE');
      expect(await db.all('SELECT * FROM unique_items')).to.deep.equal([]);
    } finally { await db.close(); }
  });
  const hostCases = results.length;
  let storageIndex = 0;
  const storageCases = createStorageConformance({ assertions, withStorage: async (use) => {
    const storage = await SqliteStorage.open(new NativeDatabase(`${nativeDatabasePath}-conformance-${++storageIndex}.sqlite`));
    try { await use(storage); } finally { await storage.close({ abortSignal: undefined }); }
  } });
  for (const test of storageCases) await check(`upstream storage: ${test.name}`, () => test.run());
  const failed = results.filter((result) => !result.passed);
  return { mode: nativeMode, passed: failed.length === 0, hostCases, storageCases: storageCases.length, total: results.length, failed, results };
}
