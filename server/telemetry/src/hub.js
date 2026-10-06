// Durable Object「Hub」：所有 WebSocket 连接都在这里。
//
// - App（role=device）发来的消息（hello / log / state / event）加上设备名和收到时间，转发给所有看板（role=viewer）；
// - 每台设备的最新状态、最近 500 条日志留在内存里，看板一连上就先发一份快照；
// - 日志按设备攒着，满 200 条或 30 秒写一块 NDJSON 到 R2（logs/日期/设备/时间.ndjson），方便事后分析。
//
// 用 WebSocket 休眠 API：没消息时 DO 可以休眠，不按时长计费；醒来后内存状态会丢，快照从存储里恢复。

const MAX_RECENT = 500;
const FLUSH_LINES = 200;
const FLUSH_MS = 30_000;

export class Hub {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.recent = [];          // 最近的日志（所有设备）
    this.states = {};          // 设备 → 最新状态
    this.hellos = {};          // 设备 → hello
    this.buf = {};             // 设备 → 待写 R2 的行
    this.loaded = false;
  }

  async load() {
    if (this.loaded) return;
    this.loaded = true;
    const s = await this.ctx.storage.get(["states", "hellos", "recent"]);
    this.states = s.get("states") || {};
    this.hellos = s.get("hellos") || {};
    this.recent = s.get("recent") || [];
  }

  async fetch(request) {
    await this.load();
    const url = new URL(request.url);
    if (url.pathname === "/event" && request.method === "POST") {
      const msg = await request.json();
      this.broadcast(msg);
      return new Response("ok");
    }
    const role = url.searchParams.get("role") === "device" ? "device" : "viewer";
    const device = (url.searchParams.get("device") || "unknown").slice(0, 60);
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role, role === "device" ? "d:" + device : "v"]);
    server.serializeAttachment({ role, device });
    if (role === "viewer") {
      server.send(JSON.stringify({
        type: "snapshot",
        states: this.states,
        hellos: this.hellos,
        recent: this.recent,
        online: this.onlineDevices(),
      }));
    } else {
      this.broadcast({ type: "online", device, online: true, t: Date.now() });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  onlineDevices() {
    return this.ctx.getWebSockets("device").map((ws) => ws.deserializeAttachment()?.device).filter(Boolean);
  }

  broadcast(msg) {
    const s = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets("viewer")) {
      try { ws.send(s); } catch (_) { /* 断开的看板 */ }
    }
  }

  async webSocketMessage(ws, data) {
    await this.load();
    const { role, device } = ws.deserializeAttachment() || {};
    if (role !== "device") return; // 看板只收不发
    let msgs;
    try {
      const v = JSON.parse(typeof data === "string" ? data : new TextDecoder().decode(data));
      msgs = Array.isArray(v) ? v : [v];   // App 断线重连后会批量补发
    } catch (_) {
      return;
    }
    const now = Date.now();
    for (const msg of msgs) {
      if (!msg || typeof msg !== "object") continue;
      msg.device = device;
      msg.recv = now;
      switch (msg.type) {
        case "hello":
          this.hellos[device] = msg;
          break;
        case "state":
          this.states[device] = msg;
          break;
        case "log":
          this.recent.push(msg);
          if (this.recent.length > MAX_RECENT) this.recent.splice(0, this.recent.length - MAX_RECENT);
          (this.buf[device] ||= []).push(JSON.stringify(msg));
          break;
      }
      this.broadcast(msg);
    }
    const pending = Object.values(this.buf).reduce((n, a) => n + a.length, 0);
    if (pending >= FLUSH_LINES) await this.flush();
    else if (pending > 0 && !(await this.ctx.storage.getAlarm())) await this.ctx.storage.setAlarm(now + FLUSH_MS);
    await this.ctx.storage.put({ states: this.states, hellos: this.hellos, recent: this.recent });
  }

  async alarm() {
    await this.load();
    await this.flush();
  }

  async flush() {
    const now = new Date();
    const day = now.toISOString().slice(0, 10);
    const stamp = now.toISOString().replace(/[:.]/g, "-");
    for (const [device, lines] of Object.entries(this.buf)) {
      if (!lines.length) continue;
      const safe = device.replace(/[^A-Za-z0-9._\-]/g, "_");
      await this.env.DATA.put(`logs/${day}/${safe}/${stamp}.ndjson`, lines.join("\n") + "\n");
    }
    this.buf = {};
  }

  async webSocketClose(ws) {
    const { role, device } = ws.deserializeAttachment() || {};
    if (role === "device") this.broadcast({ type: "online", device, online: false, t: Date.now() });
    try { ws.close(); } catch (_) {}
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws);
  }
}
