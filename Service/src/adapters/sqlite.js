// The database port on Node's built-in SQLite (node:sqlite). Same four calls as adapters/d1.js.
//
// Opening applies the files in migrations/ in name order, each once, recording them in
// `migrations_applied`. That table is this adapter's own: on D1, wrangler records the same files
// in `d1_migrations`. A database exported from D1 (`wrangler d1 export`) carries `d1_migrations`,
// so on first open its names are copied over and nothing is applied twice.

import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const MIGRATIONS = fileURLToPath(new URL("../../migrations/", import.meta.url));
const clean = (params) => params.map((p) => (p === undefined ? null : typeof p === "boolean" ? Number(p) : p));

/**
 * @param {string} path a file, or ":memory:"
 * @param {{migrations?: string}} [options]
 */
export function sqlite(path, { migrations = MIGRATIONS } = {}) {
  const db = new DatabaseSync(path);
  db.exec("PRAGMA foreign_keys = ON"); // as on D1
  if (path !== ":memory:") db.exec("PRAGMA journal_mode = WAL");
  migrate(db, migrations);

  const run = (sql, params) => { const r = db.prepare(sql).run(...clean(params)); return { changes: Number(r.changes) }; };
  return {
    raw: db,
    // Plain objects, as D1 gives (node:sqlite's rows have no prototype).
    async all(sql, ...params) { return db.prepare(sql).all(...clean(params)).map((r) => ({ ...r })); },
    async first(sql, ...params) { const r = db.prepare(sql).get(...clean(params)); return r ? { ...r } : null; },
    async run(sql, ...params) { return run(sql, params); },
    /** All or nothing. */
    async batch(list) {
      db.exec("BEGIN");
      try {
        const out = list.map((s) => run(s.sql, s.params ?? []));
        db.exec("COMMIT");
        return out;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },
    close() { db.close(); },
  };
}

function migrate(db, folder) {
  db.exec("CREATE TABLE IF NOT EXISTS migrations_applied (name TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)");
  const fromD1 = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'd1_migrations'").get();
  if (fromD1) db.exec("INSERT OR IGNORE INTO migrations_applied (name, applied_at) SELECT name, 0 FROM d1_migrations");
  const applied = new Set(db.prepare("SELECT name FROM migrations_applied").all().map((r) => r.name));
  for (const name of readdirSync(folder).filter((f) => f.endsWith(".sql")).sort()) {
    if (applied.has(name)) continue;
    db.exec("BEGIN");
    try {
      db.exec(readFileSync(join(folder, name), "utf8"));
      db.prepare("INSERT INTO migrations_applied (name, applied_at) VALUES (?, ?)").run(name, Date.now());
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw new Error(`migration ${name}: ${error.message}`);
    }
  }
}
