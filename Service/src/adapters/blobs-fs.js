// deps.blobs on Node: files in a directory, one per key (`s/<space>/<sha>`, `trash/<space>/<sha>`).
// The same calls as adapters/r2.js. A put streams to a temporary file while hashing it, and only a
// body whose SHA-256 matches is kept.

import { createHash } from "node:crypto";
import { createReadStream, createWriteStream, mkdirSync, readdirSync, renameSync, rmSync, statSync, utimesSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const KEY = /^(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+$/;

/** @param {string} dir */
export function fsBlobs(dir) {
  mkdirSync(dir, { recursive: true });
  const path = (key) => {
    if (!KEY.test(key)) throw new Error("bad blob key");
    return join(dir, ...key.split("/"));
  };
  const size = (file) => { try { return statSync(file).size; } catch { return null; } };
  let temp = 0;

  return {
    /** @param {ReadableStream|AsyncIterable<Uint8Array>} body */
    async put(key, body, { sha256 }) {
      const file = path(key);
      mkdirSync(dirname(file), { recursive: true });
      const part = `${file}.part-${process.pid}-${++temp}`;
      const hash = createHash("sha256");
      try {
        await pipeline(body, async function* (source) { for await (const chunk of source) { hash.update(chunk); yield chunk; } }, createWriteStream(part));
        if (hash.digest("hex") !== sha256) { rmSync(part, { force: true }); return false; }
        renameSync(part, file);
        return true;
      } catch (error) {
        rmSync(part, { force: true });
        throw error;
      }
    },
    async get(key) {
      const file = path(key);
      const n = size(file);
      return n === null ? null : { body: Readable.toWeb(createReadStream(file)), size: n };
    },
    async head(key) {
      const n = size(path(key));
      return n === null ? null : { size: n };
    },
    async move(from, to) {
      const source = path(from);
      if (size(source) === null) return;
      const target = path(to);
      mkdirSync(dirname(target), { recursive: true });
      renameSync(source, target);
      // The trash's 30 days count from the move, as R2's copy is new when it lands there.
      const now = new Date();
      utimesSync(target, now, now);
    },
    async delete(key) { rmSync(path(key), { force: true }); },
    async list(prefix, limit = 200) {
      const out = [];
      const walk = (folder) => {
        let names;
        try { names = readdirSync(folder, { withFileTypes: true }); } catch { return; }
        for (const entry of names.sort((a, b) => (a.name < b.name ? -1 : 1))) {
          const full = join(folder, entry.name);
          if (entry.isDirectory()) walk(full);
          else if (!entry.name.includes(".part-")) {
            const key = relative(dir, full).split(sep).join("/");
            if (key.startsWith(prefix)) out.push(key);
          }
        }
      };
      walk(dir);
      return out.slice(0, limit);
    },
  };
}
