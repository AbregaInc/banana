import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import { migrate } from "../src/mail-mailbox.js";
import { parseSenderPolicy, senderKey, senderPolicy, setSenderPolicy, blockedSender } from "../src/sender-policy.js";

test("sender rules are exact, revisioned and replay-safe after a later unblock", async () => {
  const db = new DatabaseSync(":memory:"), port = sqlitePort(db); migrate(port);
  const key = await senderKey("offers@shop.example");
  assert.equal(senderPolicy(port, key).blocked, false);
  const block = { blocked: true, revision: 0, operation: "11111111-1111-1111-1111-111111111111" };
  assert.equal(setSenderPolicy(port, key, block).body.revision, 1);
  assert.equal(setSenderPolicy(port, key, block).body.revision, 1);
  assert.equal(setSenderPolicy(port, key, { blocked: false, revision: 1, operation: "22222222-2222-2222-2222-222222222222" }).body.revision, 2);
  assert.equal(setSenderPolicy(port, key, block).status, 409);
  assert.equal(senderPolicy(port, key).blocked, false);
  assert.equal(port.exec("SELECT sender FROM sender_policy")[0].sender.includes("@"), false);
  db.close();
});

test("only one exact incoming From address is blocked; domains, outgoing and ambiguous headers are not", async () => {
  const db = new DatabaseSync(":memory:"), port = sqlitePort(db); migrate(port);
  setSenderPolicy(port, await senderKey("offers@shop.example"), { blocked: true, revision: 0, operation: "op" }, 1000);
  const message = (from, labels = ["INBOX"], extra = []) => ({ internalDate: "1001", labelIds: labels, payload: { headers: [{ name: "From", value: from }, ...extra] } });
  assert.equal(await blockedSender(port, message('Shop <OFFERS@SHOP.EXAMPLE>'), "noor@plan.example"), true);
  for (const m of [message("other@shop.example"), message("offers@shop.example.attacker.example"),
    message("offers@shop.example", ["INBOX", "SENT"]), message("offers@shop.example", ["INBOX", "DRAFT"]),
    message("offers@shop.example", ["SPAM"]), message("offers@shop.example", ["INBOX"], [{ name: "from", value: "other@example.com" }])]) {
    assert.equal(await blockedSender(port, m, "noor@plan.example"), false);
  }
  assert.equal(await blockedSender(port, message("offers@shop.example"), "offers@shop.example"), false);
  assert.equal(await blockedSender(port, { ...message("offers@shop.example"), internalDate: "999" }, "noor@plan.example"), false);
  assert.equal(await blockedSender(port, { ...message("offers@shop.example"), internalDate: undefined }, "noor@plan.example"), false);
  db.close();
});

test("sender-policy writes require an exact address, boolean, revision and operation", () => {
  const base = { email: "noor@plan.example", sender: "offers@shop.example" };
  assert.ok(parseSenderPolicy(base));
  for (const body of [{ ...base, sender: "Shop <offers@shop.example>" }, { ...base, sender: "a@example.com,b@example.com" },
    { ...base, sender: "bad\r\nFrom: other@example.com" }, { ...base, blocked: true },
    { ...base, blocked: "true", revision: 0, operation: "11111111-1111-1111-1111-111111111111" }]) {
    assert.equal(parseSenderPolicy(body), null);
  }
});
