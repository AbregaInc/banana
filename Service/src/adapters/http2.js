// A small fetch over HTTP/2 for Node (node:http2), for APNs, which only speaks HTTP/2. Node's own
// fetch talks HTTP/1.1. One session per origin, reused, reopened when it closes.

import { connect } from "node:http2";

const sessions = new Map();

function session(origin) {
  let s = sessions.get(origin);
  if (!s || s.closed || s.destroyed) {
    s = connect(origin);
    s.on("error", () => sessions.delete(origin));
    s.on("close", () => sessions.delete(origin));
    s.on("goaway", () => sessions.delete(origin));
    sessions.set(origin, s);
  }
  return s;
}

/** fetch(url, {method, headers, body}) → Response, over HTTP/2. */
export function http2Fetch(url, { method = "GET", headers = {}, body } = {}) {
  const target = new URL(url);
  return new Promise((resolve, reject) => {
    const s = session(target.origin);
    const request = s.request({ ":method": method, ":path": target.pathname + target.search, ...lower(headers) });
    request.setTimeout(15_000, () => request.close());
    const chunks = [];
    let status = 0;
    request.on("response", (h) => { status = Number(h[":status"]); });
    request.on("data", (c) => chunks.push(c));
    request.on("end", () => {
      if (!status) return reject(new Error("http2: no response"));
      resolve(new Response(status === 204 || status === 304 ? null : Buffer.concat(chunks), { status }));
    });
    request.on("error", reject);
    request.on("close", () => reject(new Error("http2: closed before an answer"))); // no-op once settled
    request.end(body ?? undefined);
  });
}

/** Closes every open session (tests, shutdown). */
export function closeHttp2() {
  for (const s of sessions.values()) s.close();
  sessions.clear();
}

const lower = (headers) => Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
