// The database port on Cloudflare D1. Same four calls as adapters/sqlite.js.
// Migrations on D1 are applied by wrangler (`wrangler d1 migrations apply banana-service`), which
// records them in its own `d1_migrations` table; the service never migrates D1 itself.

const clean = (params) => params.map((p) => (p === undefined ? null : typeof p === "boolean" ? Number(p) : p));

/** @param {any} DB the D1 binding (env.DB) */
export function d1(DB) {
  const statement = (sql, params) => DB.prepare(sql).bind(...clean(params));
  return {
    async all(sql, ...params) { return (await statement(sql, params).all()).results ?? []; },
    async first(sql, ...params) { return (await statement(sql, params).first()) ?? null; },
    async run(sql, ...params) { const r = await statement(sql, params).run(); return { changes: r.meta?.changes ?? 0 }; },
    /** All or nothing (D1 runs a batch as one transaction). */
    async batch(list) {
      if (!list.length) return [];
      const results = await DB.batch(list.map((s) => statement(s.sql, s.params ?? [])));
      return results.map((r) => ({ changes: r.meta?.changes ?? 0 }));
    },
  };
}
