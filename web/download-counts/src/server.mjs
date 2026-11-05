import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createDeps, handleDownloadRequest } from "./http.mjs";
import { openSqlite } from "./sqlite.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const port = Number(process.env.PORT || 8787);
const dbPath = process.env.COUNTS_DB || join(root, "counts.sqlite");

const db = openSqlite(dbPath);
const deps = createDeps(db, {
  trustProxy: process.env.COUNT_TRUST_PROXY === "1",
  windowSec: Number(process.env.COUNT_WINDOW_SEC || 15),
  githubToken: process.env.GITHUB_TOKEN || "",
});

const files = {
  "/": { file: join(root, "demo/index.html"), type: "text/html; charset=utf-8" },
  "/fixture": { file: join(root, "demo/fixture.html"), type: "text/html; charset=utf-8" },
};

const server = createServer(async (req, res) => {
  try {
    const host = req.headers.host || `127.0.0.1:${port}`;
    const request = new Request(new URL(req.url || "/", `http://${host}`), {
      method: req.method,
      headers: req.headers,
      body: req.method === "GET" || req.method === "HEAD" ? undefined : await readBody(req),
    });
    const handled = await handleDownloadRequest(request, { ...deps, socketIp: req.socket.remoteAddress || "" });
    if (handled) {
      res.writeHead(handled.status, Object.fromEntries(handled.headers.entries()));
      res.end(Buffer.from(await handled.arrayBuffer()));
      return;
    }
    const pathname = new URL(req.url || "/", "http://localhost").pathname;
    if (req.method === "GET" && /^\/api\/store\/download\/[^/]+\/[^/]+\/?$/.test(pathname)) {
      res.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-disposition": "attachment; filename=\"red-xai-demo.bin\"",
        "cache-control": "no-store",
      });
      res.end("demo");
      return;
    }
    const page = files[pathname];
    if (page && req.method === "GET") {
      const html = readFileSync(page.file);
      res.writeHead(200, { "content-type": page.type, "cache-control": "no-store" });
      res.end(html);
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("Not found");
  } catch (error) {
    console.error(JSON.stringify({ message: "request failed", error: error instanceof Error ? error.message : String(error) }));
    res.writeHead(500, { "content-type": "text/plain" });
    res.end("error");
  }
});

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  server.listen(port, "127.0.0.1", () => {
    const bound = server.address().port;
    console.log(JSON.stringify({ message: "download counts demo", url: `http://127.0.0.1:${bound}/`, db: dbPath }));
  });
}

export { server, deps, dbPath };
