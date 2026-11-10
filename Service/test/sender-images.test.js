// Mail sender images (src/sender-images.js, src/sender-sources.js). No real network: every outside
// fetch (DNS over HTTPS, BIMI, Gravatar, sites, Google's photo host) goes to a fake.

import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY, HOUR } from "./helpers.js";
import { TTL, contactPhotos } from "../src/sender-images.js";
import { addressParts, isAutomated, isProvider, svgProblem, fetchable, bestIconLink, sniff, sha256Hex, tags } from "../src/sender-sources.js";
import { nodeSvgRasterizer } from "../src/svg-raster.js";

const MAIL = "openid email https://www.googleapis.com/auth/gmail.modify";
const CONTACTS = `${MAIL} https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly`;

/** A PNG's first bytes: the signature and an IHDR of this size; `tag` makes each one different. */
function png(width = 128, height = 128, tag = "x") {
  const bytes = new Uint8Array(33 + tag.length);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width); view.setUint32(20, height);
  bytes.set(new TextEncoder().encode(tag), 33);
  return bytes;
}

/** The outside world: answers by URL, and a log of every URL asked. */
function web() {
  const routes = new Map();     // url → () => Response
  const dns = new Map();        // name → [records] (absent: NXDOMAIN)
  const asked = [];
  const fetch = async (url, init = {}) => {
    asked.push(String(url));
    const u = new URL(url);
    if (u.hostname === "cloudflare-dns.com") {
      const name = u.searchParams.get("name");
      const records = dns.get(name);
      return Response.json(records ? { Status: 0, Answer: records.map((r) => ({ type: 16, data: `"${r}"` })) } : { Status: 3 });
    }
    const route = routes.get(String(url));
    if (!route) return new Response("no", { status: 404 });
    return route(init);
  };
  const image = (bytes) => () => new Response(bytes, { status: 200, headers: { "content-type": "image/png" } });
  return { routes, dns, asked, fetch, image };
}

async function owner(s, code, sub, email, scopes = MAIL) {
  s.google.person(code, sub, email, `refresh-${sub}`, { scopes });
  const a = (await s.signIn(code, device(`device-${sub}`))).json;
  await s.db.run("INSERT INTO feature_access VALUES (?,?,1,NULL,?)", a.account.id, "email", s.now());
  return a;
}

const ask = (s, who, addresses) => s.call("POST", "/v1/mail/senders", { session: who.session, body: { addresses } });
const imageOf = async (s, who, id) => s.app.request(`/v1/mail/sender-image/${id}`, { headers: { authorization: `Bearer ${who.session}` } });

function world(options = {}) {
  const w = web();
  const s = setup({ deps: { outbound: w.fetch, senderAnswerWithin: options.within ?? 1_000, ...(options.deps ?? {}) } });
  return { s, w };
}

test("an address's Gravatar is found once and every Banana user after gets the same copy", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  const sam = await owner(s, "b", "sub-sam", "sam@plan.example");
  const hash = await sha256Hex("ann@gmail.com");
  w.routes.set(`https://gravatar.com/avatar/${hash}?d=404&s=128`, w.image(png(128, 128, "ann")));

  const first = await ask(s, noor, ["Ann@Gmail.com "]);
  assert.equal(first.status, 200);
  const id = first.json.senders[0].image;
  assert.match(id, /^[0-9a-f]{64}$/);
  const fetched = w.asked.length;

  const second = await ask(s, sam, ["ann@gmail.com"]);
  assert.equal(second.json.senders[0].image, id);
  assert.equal(w.asked.length, fetched, "the second user is served from the shared cache");

  const response = await imageOf(s, sam, id);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.match(response.headers.get("cache-control"), /immutable/);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), png(128, 128, "ann"));
});

test("a mail provider's brand never stands for its users, and nothing is asked of its site", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  const r = await ask(s, noor, ["noreply@gmail.com", "someone@hotmail.co.uk"]);
  assert.deepEqual(r.json.senders.map((x) => x.image), [null, null]);
  assert.ok(!w.asked.some((u) => /_bimi|_dmarc|apple-touch-icon/.test(decodeURIComponent(u))));
  assert.ok(isProvider(addressParts("x@yahoo.fr")));
  assert.ok(!isProvider(addressParts("x@shop.example.com")));
});

test("a brand at DMARC enforcement gets its BIMI logo, drawn to a PNG here", async () => {
  const { s, w } = world({ deps: { rasterSvg: await nodeSvgRasterizer() } });
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  w.dns.set("_dmarc.mail.example.com", []);
  w.dns.set("_dmarc.example.com", ["v=DMARC1; p=reject; rua=mailto:d@example.com"]);
  w.dns.set("default._bimi.mail.example.com", []);
  w.dns.set("default._bimi.example.com", ["v=BIMI1; l=https://brand.example.com/logo.svg; a="]);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" version="1.2" baseProfile="tiny-ps" viewBox="0 0 10 10"><title>Shop</title><rect width="10" height="10" fill="#f80"/></svg>`;
  w.routes.set("https://brand.example.com/logo.svg", () => new Response(svg, { headers: { "content-type": "image/svg+xml" } }));

  const r = await ask(s, noor, ["orders@mail.example.com", "ana@mail.example.com"]);
  const [a, b] = r.json.senders;
  assert.ok(a.image);
  assert.equal(a.image, b.image, "one logo for the whole domain");
  const bytes = new Uint8Array(await (await imageOf(s, noor, a.image)).arrayBuffer());
  assert.equal(sniff(bytes), "image/png");
  assert.equal(new DataView(bytes.buffer).getUint32(16), 128);
});

test("no BIMI logo without DMARC enforcement, or from an SVG that scripts or reaches out", async () => {
  const { s, w } = world({ deps: { rasterSvg: async () => png() } });
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  w.dns.set("_dmarc.example.org", ["v=DMARC1; p=none"]);
  w.dns.set("default._bimi.example.org", ["v=BIMI1; l=https://example.org/l.svg"]);
  w.dns.set("_dmarc.example.net", ["v=DMARC1; p=quarantine"]);
  w.dns.set("default._bimi.example.net", ["v=BIMI1; l=https://example.net/l.svg"]);
  w.routes.set("https://example.net/l.svg", () => new Response(`<svg><script>alert(1)</script></svg>`));
  const r = await ask(s, noor, ["ann@example.org", "ann@example.net"]);
  assert.deepEqual(r.json.senders.map((x) => x.image), [null, null]);
  assert.ok(!w.asked.includes("https://example.org/l.svg"));
  assert.ok(w.asked.includes("https://example.net/l.svg"), "the scripted SVG was fetched, then refused");

  assert.equal(svgProblem(`<svg><image href="https://tracker.example/p.png"/></svg>`), "external reference");
  assert.equal(svgProblem(`<svg onload="x()"></svg>`), "event handler");
  assert.equal(svgProblem(`<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg/>`), "entity");
  assert.equal(svgProblem(`<svg><rect style="fill:url(https://x.example/a)"/></svg>`), "external url");
  assert.equal(svgProblem(`<svg><use href="#a"/><rect fill="url(#g)"/></svg>`), null);
  assert.equal(tags("v=DMARC1; p=Reject; pct=50").pct, "50");
});

test("a site's own icon stands for its automated senders only, never for a person there", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  w.routes.set("https://example.net/apple-touch-icon.png", w.image(png(180, 180, "store")));
  const r = await ask(s, noor, ["no-reply@news.example.net", "ana.lima@example.net"]);
  assert.ok(r.json.senders[0].image);
  assert.equal(r.json.senders[1].image, null);
  assert.ok(isAutomated(addressParts("notifications+abc@x.example.net")));
  assert.ok(!isAutomated(addressParts("noor.haddad@x.example.net")));
});

test("a site icon too small for a face is not one; a linked apple-touch-icon is found", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  w.routes.set("https://example.org/apple-touch-icon.png", w.image(png(32, 32)));
  w.routes.set("https://example.org/", () => new Response(`<html><head><link rel="icon" href="/favicon.ico"><link rel="apple-touch-icon" sizes="152x152" href="/a/icon-152.png"></head><body>`, { headers: { "content-type": "text/html" } }));
  w.routes.set("https://example.org/a/icon-152.png", w.image(png(152, 152, "t")));
  const r = await ask(s, noor, ["info@example.org"]);
  const bytes = new Uint8Array(await (await imageOf(s, noor, r.json.senders[0].image)).arrayBuffer());
  assert.deepEqual(bytes, png(152, 152, "t"));
  assert.equal(bestIconLink(`<link rel="icon" sizes="16x16" href="a.png">`, "https://x.example.net/"), null);
});

test("nothing found is remembered for days, a failure for an hour, then asked again", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  const down = await sha256Hex("bo@gmail.com");
  w.routes.set(`https://gravatar.com/avatar/${down}?d=404&s=128`, () => new Response("busy", { status: 503 }));
  await ask(s, noor, ["cy@gmail.com", "bo@gmail.com"]);
  const n = w.asked.length;
  await ask(s, noor, ["cy@gmail.com", "bo@gmail.com"]);
  assert.equal(w.asked.length, n);
  s.advance(HOUR + 1);
  await ask(s, noor, ["cy@gmail.com", "bo@gmail.com"]);
  assert.equal(w.asked.length, n + 1, "only the failure is asked again");
  s.advance(TTL.none);
  await ask(s, noor, ["cy@gmail.com"]);
  assert.equal(w.asked.length, n + 2);
});

test("an answer never waits on a slow source: it is pending, and found by the next ask", async () => {
  const { s, w } = world({ within: 20 });
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  const hash = await sha256Hex("slow@gmail.com");
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  w.routes.set(`https://gravatar.com/avatar/${hash}?d=404&s=128`, async () => { await held; return new Response(png(128, 128, "s")); });
  const first = await ask(s, noor, ["slow@gmail.com"]);
  assert.deepEqual(first.json.senders, [{ address: "slow@gmail.com", pending: true }]);
  release();
  await s.settle();
  const second = await ask(s, noor, ["slow@gmail.com"]);
  assert.ok(second.json.senders[0].image);
});

test("his contact's photo is his alone: first for him, never in the shared tier, never served to another", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example", CONTACTS);
  const sam = await owner(s, "b", "sub-sam", "sam@plan.example");
  const gHash = await sha256Hex("lea@gmail.com");
  w.routes.set(`https://gravatar.com/avatar/${gHash}?d=404&s=128`, w.image(png(128, 128, "gravatar")));
  w.routes.set("https://lh3.googleusercontent.com/contact-photo?sz=128", w.image(png(128, 128, "private")));
  s.google.contactBook.connections = [{
    emailAddresses: [{ value: "Lea@Gmail.com" }],
    photos: [{ url: "https://lh3.googleusercontent.com/contact-photo", metadata: { primary: true, source: { type: "CONTACT" } } }],
  }];

  const mine = (await ask(s, noor, ["lea@gmail.com"])).json.senders[0].image;
  const theirs = (await ask(s, sam, ["lea@gmail.com"])).json.senders[0].image;
  const privateId = await sha256Hex(png(128, 128, "private"));
  assert.equal(mine, privateId);
  assert.equal(theirs, await sha256Hex(png(128, 128, "gravatar")));
  assert.equal(await s.count("sender_images", "image = ?", privateId), 0, "a contact photo never enters the shared tier");
  assert.equal(await s.count("sender_images", "key LIKE 'p:%'"), 0);
  assert.equal((await imageOf(s, sam, privateId)).status, 404);
  assert.equal((await imageOf(s, noor, privateId)).status, 200);
  const keys = await s.deps.blobs.list("senders/");
  assert.ok(keys.some((k) => k.startsWith(`senders/u/${noor.account.id}/`) && k.endsWith(privateId)));
  assert.ok(!keys.some((k) => k.startsWith("senders/shared/") && k.endsWith(privateId)));
});

test("a person's own profile photo is public, shared with every user, ahead of Gravatar", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example", CONTACTS);
  const sam = await owner(s, "b", "sub-sam", "sam@plan.example");
  w.routes.set("https://lh3.googleusercontent.com/a/profile?sz=128", w.image(png(128, 128, "profile")));
  s.google.contactBook.other = [{
    emailAddresses: [{ value: "omar@gmail.com" }],
    photos: [{ url: "https://lh3.googleusercontent.com/a/default", default: true, metadata: { source: { type: "PROFILE" } } },
             { url: "https://lh3.googleusercontent.com/a/profile", metadata: { source: { type: "PROFILE" } } }],
  }];
  const a = (await ask(s, noor, ["omar@gmail.com"])).json.senders[0].image;
  assert.equal(a, await sha256Hex(png(128, 128, "profile")));
  const b = (await ask(s, sam, ["omar@gmail.com"])).json.senders[0].image;
  assert.equal(b, a);
  assert.deepEqual(s.google.contactCalls.map((c) => c.kind).sort(), ["connections", "other"]);
});

test("contact photos are read only with the contacts grant, and go with Mail access and the account", async () => {
  const { s, w } = world();
  const plain = await owner(s, "c", "sub-cy", "cy@plan.example");
  await ask(s, plain, ["x@gmail.com"]);
  assert.equal(s.google.contactCalls.length, 0, "no contacts grant, no contacts read");

  const noor = await owner(s, "a", "sub-noor", "noor@plan.example", CONTACTS);
  w.routes.set("https://lh3.googleusercontent.com/c?sz=128", w.image(png(128, 128, "c")));
  s.google.contactBook.connections = [{ emailAddresses: [{ value: "lea@gmail.com" }], photos: [{ url: "https://lh3.googleusercontent.com/c", metadata: { source: { type: "CONTACT" } } }] }];
  await ask(s, noor, ["lea@gmail.com"]);
  assert.ok(await s.count("sender_contacts", "account_id = ?", noor.account.id));
  assert.equal((await s.deps.blobs.list(`senders/u/${noor.account.id}/`)).length, 1);

  assert.equal((await s.call("DELETE", "/v1/google/mail", { session: noor.session, body: { email: "noor@plan.example" } })).status, 204);
  assert.equal(await s.count("sender_contacts", "account_id = ?", noor.account.id), 0);
  assert.equal((await s.deps.blobs.list(`senders/u/${noor.account.id}/`)).length, 0);

  // And the whole account: his rows and copies go, the shared tier stays.
  const sam = await owner(s, "b", "sub-sam", "sam@plan.example", CONTACTS);
  await ask(s, sam, ["lea@gmail.com"]);
  assert.equal((await s.deps.blobs.list(`senders/u/${sam.account.id}/`)).length, 1);
  s.google.person("again", "sub-sam", "sam@plan.example", "refresh-again", { scopes: CONTACTS });
  assert.equal((await s.call("DELETE", "/v1/account", { body: { code: "again" }, session: sam.session })).status, 204);
  assert.equal(await s.count("sender_contacts", "account_id = ?", sam.account.id), 0);
  assert.equal(await s.count("sender_contact_syncs", "account_id = ?", sam.account.id), 0);
  assert.equal((await s.deps.blobs.list(`senders/u/${sam.account.id}/`)).length, 0);
});

test("only signed-in Mail users ask, at most 50 addresses, and no address is ever logged", async () => {
  const { s } = world();
  s.google.person("x", "sub-x", "x@plan.example", "refresh-x", { scopes: MAIL });
  const outsider = (await s.signIn("x", device("device-x"))).json;
  assert.equal((await ask(s, outsider, ["a@gmail.com"])).status, 403);
  assert.equal((await s.call("POST", "/v1/mail/senders", { body: { addresses: ["a@gmail.com"] } })).status, 401);
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example", CONTACTS);
  assert.equal((await ask(s, noor, Array.from({ length: 51 }, (_, i) => `p${i}@gmail.com`))).status, 400);
  assert.equal((await ask(s, noor, [])).status, 400);
  assert.equal((await imageOf(s, noor, "nothex")).status, 404);

  const said = [];
  const log = console.log;
  console.log = (...args) => { said.push(args.join(" ")); };
  try {
    s.google.refused.add("refresh-sub-noor");
    await ask(s, noor, ["secret.person@gmail.com", "not an address"]);
  } finally { console.log = log; }
  const hash = await sha256Hex("secret.person@gmail.com");
  assert.ok(!said.some((line) => line.includes("secret.person") || line.includes(hash)));
});

test("the service fetches public https names only, and Google photos only from Google's host", () => {
  assert.ok(fetchable("https://brand.example.com/logo.svg"));
  for (const bad of ["http://brand.example.com/l.svg", "https://127.0.0.1/x", "https://[::1]/x", "https://localhost/x",
    "https://printer.local/x", "https://a.example.com:8443/x", "https://user:pw@a.example.com/x", "https://intranet/x"]) {
    assert.ok(!fetchable(bad), bad);
  }
  assert.deepEqual(contactPhotos({ photos: [
    { url: "https://lh3.googleusercontent.com/p", metadata: { source: { type: "PROFILE" } } },
    { url: "https://lh3.googleusercontent.com/c", metadata: { primary: true, source: { type: "CONTACT" } } },
    { url: "https://lh3.googleusercontent.com/d", default: true, metadata: { source: { type: "CONTACT" } } },
  ] }), [["contact", "https://lh3.googleusercontent.com/c"], ["profile", "https://lh3.googleusercontent.com/p"]]);
  assert.equal(addressParts("not-an-address"), null);
  assert.equal(addressParts("a@b.c..d"), null);
});

test("a redirect is followed only to another public https name", async () => {
  const { s, w } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example");
  w.routes.set("https://example.com/apple-touch-icon.png", () => new Response(null, { status: 302, headers: { location: "https://127.0.0.1/icon.png" } }));
  const r = await ask(s, noor, ["info@example.com"]);
  assert.equal(r.json.senders[0].image, null);
  assert.ok(w.asked.includes("https://example.com/apple-touch-icon.png"));
  assert.ok(!w.asked.some((u) => u.includes("127.0.0.1")));
  void DAY;
});

test("contacts Google refuses are tried again in a day, not on every lookup", async () => {
  const { s } = world();
  const noor = await owner(s, "a", "sub-noor", "noor@plan.example", CONTACTS);
  s.google.contacts = async function (access, kind) { this.contactCalls.push({ kind }); throw new (await import("../src/google.js")).GoogleRefused("contacts"); };
  await ask(s, noor, ["a@gmail.com"]);
  await ask(s, noor, ["b@gmail.com"]);
  await s.settle();
  assert.equal(s.google.contactCalls.length, 1);
  s.advance(TTL.contacts + 1);
  await ask(s, noor, ["c@gmail.com"]);
  await s.settle();
  assert.equal(s.google.contactCalls.length, 2);
});
