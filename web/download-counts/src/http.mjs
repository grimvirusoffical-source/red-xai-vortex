import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ensureSchema, readMany, recordHit, WINDOW_SEC } from "./store.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const widgetSource = readFileSync(join(here, "widget.js"), "utf8");

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

export function clientIp(request, { trustProxy = false, socketIp = "" } = {}) {
  if (request.headers.get("cf-connecting-ip")) return request.headers.get("cf-connecting-ip");
  if (trustProxy) {
    const forwarded = request.headers.get("x-forwarded-for");
    if (forwarded) return forwarded.split(",")[0].trim();
  }
  return socketIp || "unknown";
}

export async function handleDownloadRequest(request, deps) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/__downloads")) return null;
  await deps.ready;
  if (url.pathname === "/__downloads/widget.js" && request.method === "GET") {
    return new Response(widgetSource, {
      headers: {
        "content-type": "text/javascript; charset=utf-8",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      },
    });
  }
  if (url.pathname === "/__downloads/counts" && request.method === "GET") {
    const hrefs = url.searchParams.getAll("href").slice(0, 40);
    const body = await readMany(deps.db, hrefs, {
      now: deps.now(),
      fetchImpl: deps.fetchImpl,
      githubToken: deps.githubToken,
    });
    return Response.json(body, { headers: jsonHeaders });
  }
  if (url.pathname === "/__downloads/hit" && request.method === "POST") {
    const type = request.headers.get("content-type") || "";
    if (!type.includes("application/json")) {
      return Response.json({ error: "json_required" }, { status: 415, headers: jsonHeaders });
    }
    let payload;
    try {
      payload = await request.json();
    } catch {
      return Response.json({ error: "bad_json" }, { status: 400, headers: jsonHeaders });
    }
    const result = await recordHit(deps.db, {
      ip: clientIp(request, deps),
      href: payload?.href,
      ua: request.headers.get("user-agent"),
      now: deps.now(),
      windowSec: deps.windowSec,
    });
    if (result.error) return Response.json(result, { status: result.status || 400, headers: jsonHeaders });
    if (result.github == null) {
      const refreshed = await readMany(deps.db, [result.href], {
        now: deps.now(),
        fetchImpl: deps.fetchImpl,
        githubToken: deps.githubToken,
      });
      const match = refreshed.items[0];
      if (match) Object.assign(result, match);
    }
    return Response.json(result, { headers: jsonHeaders });
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "GET, POST, OPTIONS" } });
  }
  return Response.json({ error: "not_found" }, { status: 404, headers: jsonHeaders });
}

export function createDeps(db, options = {}) {
  const ready = ensureSchema(db);
  return {
    db,
    ready,
    now: options.now || (() => Date.now()),
    windowSec: options.windowSec || WINDOW_SEC,
    trustProxy: Boolean(options.trustProxy),
    socketIp: options.socketIp || "",
    fetchImpl: options.fetchImpl || fetch,
    githubToken: options.githubToken || "",
  };
}
