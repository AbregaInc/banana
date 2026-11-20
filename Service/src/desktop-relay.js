// A room is scoped to the authenticated account and an unguessable pairing name.
// The worker only routes bounded ciphertext. Device secrets never reach the service.
export const maxDesktopFrame = 4 * 1024 * 1024 + 64;
export const desktopLinkName = /^Banana-[a-f0-9]{24}$/;
export const desktopNonce = /^[a-f0-9]{32}$/;
const hostLease = 15 * 60 * 1000;
const idDecoder = new TextDecoder();

function frameID(message) {
  if (!(message instanceof ArrayBuffer) || message.byteLength < 60 || message.byteLength > maxDesktopFrame) return null;
  const id = idDecoder.decode(new Uint8Array(message, 0, 32));
  return desktopNonce.test(id) ? id : null;
}

export class DesktopRelayRoom {
  constructor(state) { this.state = state; }

  fetch(request) {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const nonce = url.searchParams.get("nonce");
    const hosts = this.state.getWebSockets("host").filter((host) => {
      if (host.deserializeAttachment()?.expiresAt > Date.now()) return true;
      host.close(1001, "Relay lease ended");
      return false;
    });
    if (role === "host") {
      if (!desktopNonce.test(nonce ?? "")) return new Response(null, { status: 400 });
      if (hosts.length) return new Response(null, { status: 409 });
    } else if (role === "client") {
      if (!hosts.length) return new Response(null, { status: 503 });
      if (this.state.getWebSockets("client").length >= 4) return new Response(null, { status: 429 });
    } else return new Response(null, { status: 400 });

    const pair = new WebSocketPair();
    this.state.acceptWebSocket(pair[1], [role]);
    pair[1].serializeAttachment({ role, nonce: role === "host" ? nonce : hosts[0].deserializeAttachment().nonce,
      expiresAt: role === "host" ? Date.now() + hostLease : hosts[0].deserializeAttachment().expiresAt });
    pair[1].send(role === "host" ? "ready" : hosts[0].deserializeAttachment().nonce);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  webSocketMessage(socket, message) {
    const id = frameID(message);
    const attachment = socket.deserializeAttachment();
    if (!id || !attachment || attachment.expiresAt <= Date.now()) {
      socket.close(1008, "Invalid or expired relay frame");
      return;
    }
    const clients = this.state.getWebSockets("client");
    const pending = clients.find((client) => client.deserializeAttachment()?.id === id);
    if (attachment.role === "host") {
      if (!pending || pending.deserializeAttachment().nonce !== attachment.nonce) return;
      pending.send(message);
      pending.serializeAttachment({ ...pending.deserializeAttachment(), id: null });
      pending.close(1000, "Reply delivered");
    } else {
      const host = this.state.getWebSockets("host")[0];
      if (attachment.id || pending || !host || host.deserializeAttachment()?.nonce !== attachment.nonce) {
        socket.close(1008, "Relay unavailable");
        return;
      }
      socket.serializeAttachment({ ...attachment, id });
      host.send(message);
    }
  }

  webSocketClose(socket) {
    const attachment = socket.deserializeAttachment();
    if (attachment?.role === "host") {
      for (const client of this.state.getWebSockets("client")) {
        if (client.deserializeAttachment()?.nonce === attachment.nonce) client.close(1011, "Mac disconnected");
      }
    } else if (attachment?.id) {
      const host = this.state.getWebSockets("host")[0];
      if (host?.deserializeAttachment()?.nonce === attachment.nonce) host.send("cancel:" + attachment.id);
    }
    socket.close();
  }

  webSocketError(socket) { this.webSocketClose(socket); }
}

export function desktopRelay(namespace) {
  if (!namespace) return undefined;
  return (account, link, role, nonce, request) => {
    const room = namespace.get(namespace.idFromName(JSON.stringify([account, link])));
    const route = new URL("https://desktop-relay.internal/");
    route.searchParams.set("role", role);
    if (role === "host") route.searchParams.set("nonce", nonce);
    return room.fetch(new Request(route, { headers: { upgrade: request.headers.get("upgrade") ?? "" } }));
  };
}
