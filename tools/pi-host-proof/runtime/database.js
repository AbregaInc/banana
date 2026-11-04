function unwrap(raw) {
  const result = JSON.parse(raw);
  if (!result.ok) {
    const error = new Error(result.error.message);
    error.code = result.error.code;
    throw error;
  }
  return result.value;
}
function encode(value) {
  if (value === null) return { type: 'null' };
  if (typeof value === 'string') return { type: 'text', value };
  if (typeof value === 'bigint') return { type: 'integer', value: String(value) };
  if (value instanceof Uint8Array) return { type: 'blob', value: Array.from(value) };
  if (typeof value === 'number' && Number.isFinite(value)) {
    if (Number.isInteger(value) && !Number.isSafeInteger(value)) throw new RangeError('Unsafe SQLite integer');
    return Number.isInteger(value) ? { type: 'integer', value: String(value) } : { type: 'real', value };
  }
  throw new TypeError('Unsupported SQLite parameter');
}
function decode(value) {
  if (value.type === 'null') return null;
  if (value.type === 'blob') return Uint8Array.from(value.value);
  if (value.type === 'integer') {
    const number = Number(value.value);
    if (!Number.isSafeInteger(number)) throw new RangeError('SQLite integer exceeds JavaScript safe range');
    return number;
  }
  return value.value;
}

/** Pi's existing SqliteStorage sits above this platform facade. No Pi storage or task semantics live here. */
export class NativeDatabase {
  tail = Promise.resolve();
  closing = false;
  closed = false;
  constructor(path = nativeDatabasePath) { this.id = unwrap(nativeDatabaseOpen(path)); }
  enqueue(job) {
    if (this.closing) return Promise.reject(new Error('SQLite database is closed'));
    const result = this.tail.then(job);
    this.tail = result.catch(() => {});
    return result;
  }
  executor(scope) {
    const query = async (sql, params, mode) => {
      if (this.closed || (scope && !scope.active)) throw new Error('SQLite transaction handle is no longer active');
      const rows = unwrap(nativeDatabaseQuery(this.id, sql, JSON.stringify(params.map(encode)), mode));
      return rows.map((row) => Object.fromEntries(Object.entries(row).map(([key, value]) => [key, decode(value)])));
    };
    return {
      exec: async (sql) => { await query(sql, [], 'exec'); },
      run: async (sql, ...params) => { await query(sql, params, 'run'); },
      get: async (sql, ...params) => (await query(sql, params, 'rows'))[0],
      all: (sql, ...params) => query(sql, params, 'rows'),
    };
  }
  exec(sql) { return this.enqueue(() => this.executor().exec(sql)); }
  run(sql, ...params) { return this.enqueue(() => this.executor().run(sql, ...params)); }
  get(sql, ...params) { return this.enqueue(() => this.executor().get(sql, ...params)); }
  all(sql, ...params) { return this.enqueue(() => this.executor().all(sql, ...params)); }
  transaction(callback) {
    return this.enqueue(async () => {
      const scope = { active: true };
      const tx = this.executor(scope);
      await tx.exec('BEGIN IMMEDIATE');
      try {
        const result = await callback(tx);
        scope.active = false;
        await this.executor().exec('COMMIT');
        return result;
      } catch (error) {
        scope.active = false;
        try { await this.executor().exec('ROLLBACK'); }
        catch (rollback) { throw new AggregateError([error, rollback], 'SQLite transaction failed and rollback failed'); }
        throw error;
      }
    });
  }
  close() {
    if (this.closing) return this.tail;
    this.closing = true;
    const result = this.tail.then(() => {
      unwrap(nativeDatabaseClose(this.id));
      this.closed = true;
    });
    this.tail = result;
    return result;
  }
}
