import { createDeps, handleDownloadRequest } from "./http.mjs";

let deps;

function database(env) {
  const d1 = env.DB;
  return {
    async exec(sql) {
      await d1.exec(sql);
    },
    async get(sql, params = []) {
      return d1.prepare(sql).bind(...params).first();
    },
    async all(sql, params = []) {
      const result = await d1.prepare(sql).bind(...params).all();
      return result.results || [];
    },
    async run(sql, params = []) {
      const result = await d1.prepare(sql).bind(...params).run();
      return { changes: result.meta?.changes ?? 0 };
    },
    // Each D1 statement commits. The rate-limit INSERT is the gate, so a
    // second caller cannot also increment. There is no interactive
    // transaction API here; batch() cannot skip the increment after a read.
    async transaction(fn) {
      return fn(this);
    },
  };
}

function dependencies(env) {
  if (!deps) {
    deps = createDeps(database(env), {
      githubToken: env.GITHUB_TOKEN || "",
      windowSec: Number(env.COUNT_WINDOW_SEC || 15),
    });
  }
  return deps;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname.startsWith("/__downloads")) {
        const response = await handleDownloadRequest(request, dependencies(env));
        return response || new Response("Not found", { status: 404 });
      }
      const origin = await fetch(request, { redirect: "manual" });
      const type = origin.headers.get("content-type") || "";
      if (!type.includes("text/html") || !origin.body) return origin;
      return new HTMLRewriter()
        .on("body", {
          element(element) {
            element.append('<script src="/__downloads/widget.js" defer></script>', { html: true });
          },
        })
        .transform(origin);
    } catch (error) {
      console.error(JSON.stringify({
        message: "download counts worker failed",
        error: error instanceof Error ? error.message : String(error),
        path: url.pathname,
      }));
      if (url.pathname.startsWith("/__downloads")) {
        return Response.json({ error: "unavailable" }, { status: 503 });
      }
      if (request.method === "GET" || request.method === "HEAD") {
        return fetch(request, { redirect: "manual" });
      }
      return new Response("Bad gateway", { status: 502 });
    }
  },
};
