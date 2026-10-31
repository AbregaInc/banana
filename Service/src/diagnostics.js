// Crash, hang and performance reports from the apps' MetricKit (docs/design/DIAGNOSTICS.md).
// Anonymous by construction: a batch says only which build on which platform, and MetricKit's own
// JSON, which holds call stacks, timings and the OS, nothing about the person.

import { CHANNELS, PLATFORMS } from "./usage.js";

export const KINDS = ["crash", "hang", "cpu", "disk", "metrics"];
export const MOST_PER_BATCH = 10;
export const MOST_PAYLOAD = 65_536;
export const MOST_PER_DAY = 20_000;   // a flood stops here; real reports are a few a day per copy
export const KEEP = 90 * 24 * 60 * 60 * 1000;

const word = (value, list) => (typeof value === "string" && list.includes(value) ? value : null);

/**
 * One batch: { platform, channel, version, os, reports: [{kind, signature?, payload: object}] }.
 * Returns the rows to keep, or null when the batch itself isn't one of ours. A report that isn't
 * well formed or is too large is dropped alone.
 */
export function reportRows(batch) {
  if (!batch || typeof batch !== "object") return null;
  const platform = word(batch.platform, PLATFORMS);
  const channel = word(batch.channel, CHANNELS);
  const version = typeof batch.version === "string" && /^[0-9.]{1,12} \([0-9]{1,6}\)$/.test(batch.version) ? batch.version : null;
  const os = typeof batch.os === "string" && /^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$/.test(batch.os) ? batch.os : null;
  if (!platform || !channel || !version || !Array.isArray(batch.reports)) return null;
  const out = [];
  for (const r of batch.reports.slice(0, MOST_PER_BATCH)) {
    const kind = word(r?.kind, KINDS);
    if (!kind || !r.payload || typeof r.payload !== "object") continue;
    const payload = JSON.stringify(r.payload);
    if (payload.length > MOST_PAYLOAD) continue;
    const signature = typeof r.signature === "string" && r.signature.length <= 200 ? r.signature : null;
    out.push({ kind, signature, platform, channel, version, os, payload });
  }
  return out;
}
