// The sync protocol fixtures shared with the app (Shared/SyncProtocolFixtures.json, made by
// tools/make-protocol-fixtures.mjs): every case replayed against space.js, answers compared whole.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import * as space from "../src/space.js";

const FIXTURES = JSON.parse(readFileSync(new URL("../../Shared/SyncProtocolFixtures.json", import.meta.url), "utf8"));

test("protocol fixtures: every case's answers, from an empty space", () => {
  assert.ok(FIXTURES.cases.length >= 11);
  for (const kase of FIXTURES.cases) {
    const port = sqlitePort(new DatabaseSync(":memory:"));
    for (const [i, step] of kase.steps.entries()) {
      if (step.sync) {
        const { device, platform, since, changes, now, pageRecords } = step.sync;
        const { answer } = space.sync(port, { account: "acc", device, platform, since, changes: structuredClone(changes), now, ...(pageRecords ? { pageRecords } : {}) });
        assert.match(answer.epoch, /^[0-9a-f]{24}$/);
        delete answer.epoch;
        assert.deepEqual(answer, step.answer, `${kase.name}, step ${i + 1}`);
      } else if (step.consent) {
        space.setConsent(port, step.consent, { version: 1, at: step.sync?.now ?? 0, device: "phone-0001" });
      } else if (step.blob) {
        space.recordBlob(port, step.blob, step.size, 0, step.type);
      } else {
        assert.fail(`${kase.name}, step ${i + 1}: unknown step`);
      }
    }
  }
});
