// A push about a feature goes only to devices whose build has it and whose person has it on
// (src/device-features.js). Mail is the first such feature.

import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken } from "./helpers.js";
import { pushTo } from "../src/push.js";
import { deviceHas, parseCapabilities } from "../src/device-features.js";
import { parseDevice } from "../src/app.js";

const MAIL = { payload: { aps: { "content-available": 1 }, b: { k: "mail" } }, collapseId: "mail", feature: "mail" };

async function account() {
  const s = setup();
  s.google.person("noor", "sub-noor", "noor@plan.example");
  const devices = {
    // A build with Mail and the module on.
    mailOn: device("device-mail-on", { push: pushToken(1), capabilities: ["mail"] }),
    // A build with Mail, the module switched off: it reports no mail.
    mailOff: device("device-mail-off", { push: pushToken(2), bundle: "app.banana.Banana.beta", capabilities: [] }),
    // A Stable build (no Mail compiled in), reporting.
    stable: device("device-stable", { push: pushToken(3), platform: "mac", capabilities: [] }),
    // Stable from before capabilities: says nothing.
    oldStable: device("device-old-stable", { push: pushToken(4) }),
    // A Beta from before capabilities (Mac Beta 112): says nothing, has Mail built in.
    oldBeta: device("device-old-beta", { push: pushToken(5), platform: "mac", bundle: "app.banana.Banana.beta" }),
  };
  let session;
  for (const d of Object.values(devices)) {
    const answer = await s.signIn("noor", d, session);
    assert.equal(answer.status, 200, answer.text);
    session ??= answer.json.session;
  }
  const id = (await s.db.first("SELECT account_id FROM devices WHERE id = ?", devices.mailOn.id)).account_id;
  const tokens = () => s.apns.sends.map((p) => p.token).sort();
  return { s, devices, session, id, tokens };
}

test("a mail push reaches the devices with Mail on, and a Beta from before capabilities", async () => {
  const { s, devices, id, tokens } = await account();
  await pushTo(s.deps, id, MAIL);
  assert.deepEqual(tokens(), [devices.mailOn.push, devices.oldBeta.push].sort());
});

test("a push about the app itself still reaches every device", async () => {
  const { s, devices, id, tokens } = await account();
  await pushTo(s.deps, id, { payload: { aps: { "content-available": 1 }, b: { k: "calendar" } }, collapseId: "calendar" });
  assert.deepEqual(tokens(), Object.values(devices).map((d) => d.push).sort());
});

test("switching the module off or on re-registers, and the next mail push follows it", async () => {
  const { s, devices, session, id, tokens } = await account();
  const { id: onId, ...on } = devices.mailOn;
  assert.equal((await s.call("PUT", `/v1/devices/${onId}`, { session, body: { ...on, capabilities: [] } })).status, 204);
  const { id: offId, ...off } = devices.mailOff;
  assert.equal((await s.call("PUT", `/v1/devices/${offId}`, { session, body: { ...off, capabilities: ["mail"] } })).status, 204);
  await pushTo(s.deps, id, MAIL);
  assert.deepEqual(tokens(), [devices.mailOff.push, devices.oldBeta.push].sort());
});

test("an old Beta that updates to a reporting build follows what it reports, not its bundle", async () => {
  const { s, devices, session, id, tokens } = await account();
  const { id: betaId, ...beta } = devices.oldBeta;
  assert.equal((await s.call("PUT", `/v1/devices/${betaId}`, { session, body: { ...beta, capabilities: [] } })).status, 204);
  assert.equal((await s.db.first("SELECT capabilities FROM devices WHERE id = ?", betaId)).capabilities, "[]");
  await pushTo(s.deps, id, MAIL);
  assert.deepEqual(tokens(), [devices.mailOn.push]);
});

test("an unknown feature is a programming error, not a push to everyone", async () => {
  const { s, id } = await account();
  await assert.rejects(pushTo(s.deps, id, { ...MAIL, feature: "mial" }), /unknown feature/);
  assert.equal(s.apns.sends.length, 0);
});

test("capabilities in a registration: optional, a short list of names, else refused", () => {
  const base = { id: "device-12345678", platform: "iphone", pushEnv: "production", bundle: "app.banana.Banana" };
  assert.equal(parseDevice(base).capabilities, undefined, "an older build says nothing");
  assert.deepEqual(parseDevice({ ...base, capabilities: [] }).capabilities, []);
  assert.deepEqual(parseDevice({ ...base, capabilities: ["mail", "mail", "futureThing"] }).capabilities, ["futureThing", "mail"]);
  for (const bad of ["mail", [1], ["Mail!"], ["x".repeat(40)], Array.from({ length: 17 }, (_, i) => `f${i}`)]) {
    assert.equal(parseDevice({ ...base, capabilities: bad }), null, JSON.stringify(bad));
  }
  assert.equal(parseCapabilities(undefined), undefined);
  assert.equal(deviceHas({ capabilities: "not json", bundle: "x.beta" }, "mail"), false);
  assert.equal(deviceHas({ capabilities: null, bundle: "x.beta" }, "mail"), true, "the documented transition");
  assert.equal(deviceHas({ capabilities: null, bundle: "x" }, "mail"), false);
});
