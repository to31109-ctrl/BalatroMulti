// Balatro Co-op relay — Cloudflare Worker + Durable Object.
//
// One Durable Object per room. The host opens a WebSocket to /ws?role=host and receives
// a room code; friends open /ws?role=join&code=XXXXX. The object forwards text frames:
//   client -> host :  "<cid>|<payload>"            (payload is the mod's JSON line)
//   host   -> DO   :  "<cid>|<payload>" or "*|<payload>" (one client, or everyone)
//   DO     -> host :  "sys|join|<cid>" / "sys|leave|<cid>"
//   DO     -> client: "<payload>"                    (unchanged)
// Uses the WebSocket Hibernation API so idle rooms cost nothing on the free plan.

const ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const CODE_LEN = 5;
const MAX_CLIENTS = 8;
const MAX_FRAME = 256 * 1024;

function randomCode() {
  const bytes = new Uint8Array(CODE_LEN);
  crypto.getRandomValues(bytes);
  let s = '';
  for (const b of bytes) s += ALPHABET[b % ALPHABET.length];
  return s;
}

function normalizeCode(code) {
  return (code || '').toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response('Balatro Co-op relay OK', { status: 200, headers: { 'content-type': 'text/plain' } });
    }
    if (url.pathname !== '/ws') return new Response('not found', { status: 404 });
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });

    const role = url.searchParams.get('role');
    let code = normalizeCode(url.searchParams.get('code'));
    if (role === 'host') {
      code = randomCode();
    } else if (role !== 'join' || code.length !== CODE_LEN) {
      return new Response('bad role or code', { status: 400 });
    }
    const id = env.ROOMS.idFromName(code);
    const stub = env.ROOMS.get(id);
    const fwd = new URL(request.url);
    fwd.searchParams.set('code', code);
    return stub.fetch(new Request(fwd.toString(), request));
  },
};

export class Room {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  hostSocket() {
    const list = this.state.getWebSockets('host');
    return list.length ? list[0] : null;
  }

  clientSockets() {
    return this.state.getWebSockets('client');
  }

  clientById(cid) {
    for (const ws of this.clientSockets()) {
      const a = ws.deserializeAttachment();
      if (a && a.cid === cid) return ws;
    }
    return null;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = url.searchParams.get('role');
    const code = url.searchParams.get('code');
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (role === 'host') {
      const existing = this.hostSocket();
      if (existing) {
        try { existing.close(4000, 'replaced by a new host connection'); } catch (e) {}
      }
      // a fresh host means a fresh room: drop leftover clients
      for (const ws of this.clientSockets()) { try { ws.close(4001, 'room restarted'); } catch (e) {} }
      await this.state.storage.put('nextCid', 2);
      server.serializeAttachment({ role: 'host', code });
      this.state.acceptWebSocket(server, ['host']);
      server.send('sys|code|' + code);
    } else {
      const host = this.hostSocket();
      if (!host) {
        return new Response('no such room', { status: 404 });
      }
      if (this.clientSockets().length >= MAX_CLIENTS) {
        return new Response('room full', { status: 429 });
      }
      let cid = (await this.state.storage.get('nextCid')) || 2;
      await this.state.storage.put('nextCid', cid + 1);
      server.serializeAttachment({ role: 'client', cid, code });
      this.state.acceptWebSocket(server, ['client', 'cid:' + cid]);
      server.send('sys|welcome|' + cid);
      try { host.send('sys|join|' + cid); } catch (e) {}
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    if (typeof message !== 'string' || message.length > MAX_FRAME) return;
    const a = ws.deserializeAttachment();
    if (!a) return;
    if (a.role === 'host') {
      const sep = message.indexOf('|');
      if (sep < 0) return;
      const target = message.slice(0, sep);
      const payload = message.slice(sep + 1);
      if (target === '*') {
        for (const c of this.clientSockets()) { try { c.send(payload); } catch (e) {} }
      } else {
        const c = this.clientById(Number(target));
        if (c) { try { c.send(payload); } catch (e) {} }
      }
    } else {
      const host = this.hostSocket();
      if (host) { try { host.send(a.cid + '|' + message); } catch (e) {} }
    }
  }

  webSocketClose(ws, code, reason) {
    this.dropped(ws);
  }

  webSocketError(ws, error) {
    this.dropped(ws);
  }

  dropped(ws) {
    const a = ws.deserializeAttachment();
    if (!a) return;
    if (a.role === 'host') {
      for (const c of this.clientSockets()) { try { c.close(4002, 'host left'); } catch (e) {} }
    } else {
      const host = this.hostSocket();
      if (host) { try { host.send('sys|leave|' + a.cid); } catch (e) {} }
    }
  }
}
