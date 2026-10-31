// deps.blobs on Workers: an R2 bucket (binding BLOBS). Bodies stream; nothing is held in memory.
// The same calls as adapters/blobs-fs.js.

/** @param {any} bucket the R2 binding (env.BLOBS) */
export function r2Blobs(bucket) {
  return {
    /** Streams the body in; R2 checks the hash. false when it didn't match. */
    async put(key, body, { sha256 }) {
      try { await bucket.put(key, body, { sha256 }); return true; }
      catch (error) {
        if (/sha-?256|checksum|digest/i.test(String(error?.message))) return false;
        throw error;
      }
    },
    async get(key) {
      const object = await bucket.get(key);
      return object && { body: object.body, size: object.size };
    },
    async head(key) {
      const object = await bucket.head(key);
      return object && { size: object.size };
    },
    /** R2 has no rename: a copy, then the delete. Nothing there is nothing to move. */
    async move(from, to) {
      const object = await bucket.get(from);
      if (!object) return;
      await bucket.put(to, object.body);
      await bucket.delete(from);
    },
    delete: (key) => bucket.delete(key),
    async list(prefix, limit = 200) {
      return (await bucket.list({ prefix, limit })).objects.map((o) => o.key);
    },
  };
}
