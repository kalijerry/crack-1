// 地磁定位云端后台（Cloudflare Worker）。
//
// - GET  /                       网页看板（打开后输入口令）
// - GET  /ws?role=device|viewer  WebSocket：App 发日志 / 状态，看板实时接收（转给 Durable Object「Hub」）
// - PUT  /api/sessions/<名字>.zip  上传采集会话（R2：sessions/）
// - GET  /api/sessions           会话列表；GET /api/sessions/<名字>.zip 下载
// - PUT  /api/maps/<id>          上传地图 JSON（看板画地图用）；GET /api/maps/<id>
// - PUT  /api/reports/<名字>.json 上传评估报告（hpass-eval 的 --json）；GET /api/reports 列表
// - GET  /api/logs?day=YYYY-MM-DD 某天的日志分块列表；GET /api/logs/<key> 取一块
//
// 鉴权：所有接口都要口令（secret TOKEN），放在 Authorization: Bearer … 或 ?token=…（WebSocket 用后者）。

import { Hub } from "./hub.js";
import DASHBOARD from "./dashboard.html";

export { Hub };

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8" } });

function authorized(request, env, url) {
  if (!env.TOKEN) return false; // 没配口令就全部拒绝，防止裸奔
  const h = request.headers.get("authorization") || "";
  const t = h.startsWith("Bearer ") ? h.slice(7) : url.searchParams.get("token");
  if (!t || t.length !== env.TOKEN.length) return false;
  // 定长比较
  let diff = 0;
  for (let i = 0; i < t.length; i++) diff |= t.charCodeAt(i) ^ env.TOKEN.charCodeAt(i);
  return diff === 0;
}

const safeName = (s) => /^[A-Za-z0-9._\-]{1,120}$/.test(s);

async function listPrefix(env, prefix, limit = 500) {
  const out = [];
  let cursor;
  do {
    const r = await env.DATA.list({ prefix, cursor, limit: 1000 });
    for (const o of r.objects) out.push({ key: o.key, size: o.size, uploaded: o.uploaded });
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor && out.length < limit);
  return out.sort((a, b) => (a.uploaded < b.uploaded ? 1 : -1));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/" || path === "/index.html") {
      return new Response(DASHBOARD, { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    if (!authorized(request, env, url)) return json({ error: "口令不对" }, 401);

    // WebSocket → Hub（全局一个实例）
    if (path === "/ws") {
      if (request.headers.get("upgrade") !== "websocket") return json({ error: "需要 WebSocket" }, 426);
      const id = env.HUB.idFromName("main");
      return env.HUB.get(id).fetch(request);
    }

    // 会话
    if (path === "/api/sessions" && request.method === "GET") {
      return json(await listPrefix(env, "sessions/"));
    }
    let m = path.match(/^\/api\/sessions\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name)) return json({ error: "名字不合法" }, 400);
      const key = "sessions/" + name;
      if (request.method === "PUT") {
        await env.DATA.put(key, request.body, { httpMetadata: { contentType: "application/zip" } });
        const hub = env.HUB.get(env.HUB.idFromName("main"));
        await hub.fetch(new Request("https://hub/event", {
          method: "POST",
          body: JSON.stringify({ type: "event", name: "session_uploaded", session: name, t: Date.now() }),
        }));
        return json({ ok: true, key });
      }
      if (request.method === "GET") {
        const o = await env.DATA.get(key);
        if (!o) return json({ error: "没有这个会话" }, 404);
        return new Response(o.body, { headers: { "content-type": "application/zip", "content-disposition": `attachment; filename="${name}"` } });
      }
    }

    // 地图
    m = path.match(/^\/api\/maps\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "maps/" + id + ".json";
      if (request.method === "PUT") {
        await env.DATA.put(key, request.body, { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get(key);
      if (!o) return json({ error: "没有这张地图" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 云端地图包（地图 + 磁场 + 蓝牙 + 视觉特征地图，App 打包上传、别的手机拉取）
    if (path === "/api/packages" && request.method === "GET") {
      const out = [];
      let cursor;
      do {
        const r = await env.DATA.list({ prefix: "packages/", cursor, include: ["customMetadata"] });
        for (const o of r.objects) {
          const m = o.customMetadata || {};
          out.push({ id: o.key.slice("packages/".length).replace(/\.hpmp$/, ""), size: o.size, uploaded: o.uploaded,
                     name: m.name ? decodeURIComponent(m.name) : "", kind: m.kind || "", version: Number(m.version || 0),
                     fieldCells: Number(m.fieldCells || 0), bleTags: Number(m.bleTags || 0) });
        }
        cursor = r.truncated ? r.cursor : undefined;
      } while (cursor);
      return json(out.sort((a, b) => b.version - a.version));
    }
    m = path.match(/^\/api\/packages\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "packages/" + id + ".hpmp";
      if (request.method === "PUT") {
        const h = (k) => request.headers.get(k) || "";
        const version = Number(h("x-map-version") || 0);
        const old = await env.DATA.head(key);
        if (old && Number(old.customMetadata?.version || 0) > version) {
          return json({ error: "云端已经有更新的版本", version: Number(old.customMetadata.version) }, 409);
        }
        await env.DATA.put(key, request.body, {
          httpMetadata: { contentType: "application/octet-stream" },
          customMetadata: { name: h("x-map-name"), kind: h("x-map-kind"), version: String(version),
                            fieldCells: h("x-field-cells"), bleTags: h("x-ble-tags") },
        });
        const hub = env.HUB.get(env.HUB.idFromName("main"));
        await hub.fetch(new Request("https://hub/event", {
          method: "POST",
          body: JSON.stringify({ type: "event", name: "map_package_uploaded", session: id, t: Date.now() }),
        }));
        return json({ ok: true, id, version });
      }
      if (request.method === "GET") {
        const o = await env.DATA.get(key);
        if (!o) return json({ error: "没有这个地图包" }, 404);
        return new Response(o.body, { headers: { "content-type": "application/octet-stream",
          "x-map-version": o.customMetadata?.version || "0" } });
      }
    }

    // 评估报告
    if (path === "/api/reports" && request.method === "GET") return json(await listPrefix(env, "reports/"));
    m = path.match(/^\/api\/reports\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name)) return json({ error: "名字不合法" }, 400);
      if (request.method === "PUT") {
        await env.DATA.put("reports/" + name, request.body, { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get("reports/" + name);
      if (!o) return json({ error: "没有" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 日志分块
    if (path === "/api/logs") {
      const day = url.searchParams.get("day") || new Date().toISOString().slice(0, 10);
      return json(await listPrefix(env, "logs/" + day + "/"));
    }
    m = path.match(/^\/api\/logs\/(.+)$/);
    if (m) {
      const key = "logs/" + decodeURIComponent(m[1]);
      const o = await env.DATA.get(key);
      if (!o) return json({ error: "没有" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/x-ndjson; charset=utf-8" } });
    }

    return json({ error: "没有这个接口" }, 404);
  },
};
