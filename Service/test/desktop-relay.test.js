import assert from "node:assert/strict";
import { test } from "node:test";
import { desktopRelay, DesktopRelayRoom } from "../src/desktop-relay.js";
import { setup, device } from "./helpers.js";

class Socket {
  constructor(role, nonce) { this.attachment = { role, nonce, expiresAt: Date.now() + 60_000 }; this.sent = []; this.closed = []; }
  deserializeAttachment() { return this.attachment; }
  serializeAttachment(value) { this.attachment = value; }
  send(value) { this.sent.push(value); }
  close(...result) { this.closed.push(result); }
}

const nonce = "f".repeat(32);
const id = "a".repeat(32);
const frame = (id) => new TextEncoder().encode(id + "opaque sealed data, unreadable by relay").buffer;

test("one client request is sent only to the host and the reply only to that client", () => {
  const host = new Socket("host", nonce), client = new Socket("client", nonce), other = new Socket("client", nonce);
  const room = new DesktopRelayRoom({ getWebSockets: (role) => role === "host" ? [host] : [client, other] });
  const request = frame(id);
  room.webSocketMessage(client, request);
  assert.deepEqual(host.sent, [request]);
  room.webSocketMessage(other, request);
  assert.equal(other.closed[0][0], 1008);
  assert.deepEqual(host.sent, [request]);
  room.webSocketMessage(host, frame("b".repeat(32)));
  assert.deepEqual(client.sent, []);
  const response = frame(id);
  room.webSocketMessage(host, response);
  assert.deepEqual(client.sent, [response]);
  assert.deepEqual(other.sent, []);
  assert.equal(client.closed[0][0], 1000);
  room.webSocketClose(client);
  assert.deepEqual(host.sent, [request]);
});

test("a stale attachment is rejected and an interrupted request cancels its host job", () => {
  const host = new Socket("host", nonce), client = new Socket("client", nonce), old = new Socket("client", "e".repeat(32));
  const room = new DesktopRelayRoom({ getWebSockets: (role) => role === "host" ? [host] : [client, old] });
  const request = frame(id);
  room.webSocketMessage(old, request);
  assert.equal(old.closed[0][0], 1008);
  room.webSocketMessage(client, request);
  room.webSocketClose(client);
  assert.deepEqual(host.sent, [request, "cancel:" + id]);
  room.webSocketClose(host);
  assert.equal(client.closed[1][0], 1011);
  assert.equal(old.closed.length, 1);
});

test("relay rooms are account scoped and receive no bearer credentials", async () => {
  const seen = [];
  const relay = desktopRelay({
    idFromName: (name) => name,
    get: (scope) => ({ fetch: (request) => {
      seen.push({ scope, auth: request.headers.get("authorization") });
      return new Response(null, { status: 204 });
    } }),
  });
  const url = "https://plan.example/v1/desktop/Banana-" + "a".repeat(24) + "/client";
  const request = new Request(url, { headers: { upgrade: "websocket", authorization: "Bearer opaque-token" } });
  await relay("one", "link", "client", undefined, request);
  await relay("two", "link", "client", undefined, request);
  assert.notEqual(seen[0].scope, seen[1].scope);
  assert.ok(seen.every((record) => record.auth === null));
});

test("the service rejects an unauthenticated upgrade before reaching the relay room", async () => {
  const s = setup();
  const route = "/v1/desktop/Banana-" + "a".repeat(24) + "/client";
  assert.equal((await s.call("GET", route, { headers: { upgrade: "websocket" } })).status, 401);
  s.google.person("code", "subject", "noor@plan.example");
  const { session } = (await s.signIn("code", device("phone-0001"))).json;
  assert.equal((await s.call("GET", route, { session, headers: { upgrade: "websocket" } })).status, 404);
});
