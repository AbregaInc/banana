// Builds Shared/SyncProtocolFixtures.json: each case's steps run through the service's own
// space.js (node:sqlite), and its answers are written down (epoch left out: it is random). The app's
// suite (BananaTests, MemorySyncServer) and test/protocol.test.js both replay the file.
// Run `npm run fixtures` after a protocol change, and review the diff before committing it.
import { DatabaseSync } from "node:sqlite";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import * as space from "../src/space.js";

const OUT = fileURLToPath(new URL("../../Shared/SyncProtocolFixtures.json", import.meta.url));

const NOW = 1760900000000;
const c = (ms, counter = 0, device = "phone") => `${String(ms).padStart(13, "0")}.${counter.toString(16).padStart(4, "0")}.${device}`;
const SHA = "a".repeat(64);
const phone = { device: "phone-0001", platform: "iphone" }, mac = { device: "mac-0001", platform: "mac" };
const change = (type, id, set, clock, del = null) => ({ type, id, set, clocks: Object.fromEntries(Object.keys(set).map((k) => [k, clock])), delete: del, schema: 1 });
const sync = (who, since, changes, extra = {}) => ({ sync: { ...who, since, changes, now: NOW, ...extra } });

const cases = [
  { name: "a write comes back applied and in the changes; another device pulls it", steps: [
    sync(phone, 0, [change("core.smartSettings", "s1", { theme: "dark", week: 1 }, c(NOW))]),
    sync(mac, 0, []),
  ] },
  { name: "a retry is no change: same clocks back, no new seq", steps: [
    sync(phone, 0, [change("core.smartSettings", "s1", { theme: "dark" }, c(NOW))]),
    sync(phone, 1, [change("core.smartSettings", "s1", { theme: "dark" }, c(NOW))]),
  ] },
  { name: "a clock more than five minutes ahead is refused, whole; five minutes exactly is taken", steps: [
    sync(phone, 0, [{ type: "core.smartSettings", id: "s1", set: { theme: "dark", week: 2 }, clocks: { theme: c(NOW), week: c(NOW + 300001) }, delete: null, schema: 1 }]),
    sync(phone, 0, [change("core.smartSettings", "s1", { theme: "dark", week: 2 }, c(NOW + 300000))]),
  ] },
  { name: "a delete from a fast clock is refused too", steps: [
    sync(phone, 0, [change("core.smartSettings", "s1", { theme: "dark" }, c(NOW))]),
    sync(phone, 1, [change("core.smartSettings", "s1", {}, c(NOW), c(NOW + 600000))]),
  ] },
  { name: "applied carries the space's delete clock", steps: [
    sync(phone, 0, [change("plan.extra", "x1", { title: "Swim" }, c(NOW))]),
    sync(mac, 0, [change("plan.extra", "x1", {}, c(NOW), c(NOW + 1000, 0, "mac"))]),
  ] },
  { name: "T2 needs the Health consent, and every answer says it", steps: [
    sync(phone, 0, [change("food.meal", "m1", { title: "Oats" }, c(NOW))]),
    { consent: "health" },
    sync(phone, 0, [change("food.meal", "m1", { title: "Oats" }, c(NOW))]),
  ] },
  { name: "hub-only types are written only by the iPhone", steps: [
    sync(mac, 0, [change("core.hubStatus", "status", { v: { charging: true } }, c(NOW, 0, "mac"))]),
    sync(phone, 0, [change("core.hubStatus", "status", { v: { charging: true } }, c(NOW))]),
  ] },
  { name: "a patch naming a blob the space doesn't have waits for it", steps: [
    sync(phone, 0, [change("podcast.listen", "l1", { route: { $blob: SHA, size: 3, ext: "json" } }, c(NOW))]),
    { blob: SHA, size: 3, type: "podcast.listen" },
    sync(phone, 0, [change("podcast.listen", "l1", { route: { $blob: SHA, size: 3, ext: "json" } }, c(NOW))]),
  ] },
  { name: "paging by count: next is the last seq returned, more says ask again", steps: [
    sync(phone, 0, [change("plan.extra", "a", { title: "A" }, c(NOW)), change("plan.extra", "b", { title: "B" }, c(NOW)),
                    change("plan.extra", "c", { title: "C" }, c(NOW))]),
    sync(mac, 0, [], { pageRecords: 2 }),
    sync(mac, 2, [], { pageRecords: 2 }),
  ] },
  { name: "a cursor past the head reads the space from the start", steps: [
    sync(phone, 0, [change("plan.extra", "a", { title: "A" }, c(NOW))]),
    sync(mac, 50, []),
  ] },
  { name: "an unknown type is refused", steps: [
    sync(phone, 0, [change("plan.unknownKind", "a", { title: "A" }, c(NOW))]),
  ] },
];

for (const kase of cases) {
  const port = sqlitePort(new DatabaseSync(":memory:"));
  for (const step of kase.steps) {
    if (step.sync) {
      const { device, platform, since, changes, now, pageRecords } = step.sync;
      const { answer } = space.sync(port, { account: "acc", device, platform, since, changes: structuredClone(changes), now, ...(pageRecords ? { pageRecords } : {}) });
      delete answer.epoch;
      step.answer = answer;
    } else if (step.consent) {
      space.setConsent(port, step.consent, { version: 1, at: NOW, device: "phone-0001" });
    } else if (step.blob) {
      space.recordBlob(port, step.blob, step.size, NOW, step.type);
    }
  }
}

const out = {
  comment: "The sync protocol (docs/design/DATA-PLATFORM.md §4) as request/answer pairs, run by both suites: Service/test (space.js) and BananaTests (MemorySyncServer). Each case starts from an empty space and runs its steps in order: `sync` (device, platform, since, changes, now, optional pageRecords) must give `answer`; `consent` grants a consent; `blob` puts a blob in the space's index. `epoch` is random and left out of the answers. The answers were made by running Service/src/space.js.",
  cases,
};
writeFileSync(OUT, JSON.stringify(out, null, 2) + "\n");
console.log(`${cases.length} cases`);
