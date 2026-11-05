import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { platformFromUA, itemFromHref, mergeView } from "../src/platform.mjs";
import { openSqlite } from "../src/sqlite.mjs";
import { ensureSchema, readMany, recordHit } from "../src/store.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const storeHref = "/api/store/download/vortex/darwin-universal";
const chipHref = "/api/store/download/vortex/windows-amd64";
const githubHref = "https://github.com/grimvirusoffical-source/red-xai-vortex/releases/download/v2.8/Vortex-2.8-mac.dmg";

test("user agent maps onto the device that clicked", () => {
  assert.equal(platformFromUA("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"), "windows");
  assert.equal(platformFromUA("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)"), "macos");
  assert.equal(platformFromUA("Mozilla/5.0 (X11; Linux x86_64)"), "linux");
  assert.equal(platformFromUA("Mozilla/5.0 (Linux; Android 14; Pixel 8) Chrome Mobile"), "android");
  assert.equal(platformFromUA("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"), "ios");
  assert.equal(platformFromUA("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)"), "ios");
  assert.equal(platformFromUA("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Mobile"), "ios");
  assert.equal(platformFromUA("curl/8.0"), "other");
});

test("store downloads share one counter per app and github assets stay separate", () => {
  assert.equal(itemFromHref(storeHref).id, itemFromHref(chipHref).id);
  assert.equal(itemFromHref(githubHref).kind, "github");
  assert.equal(itemFromHref("https://example.com/not-a-download"), null);
  assert.equal(itemFromHref("javascript:alert(1)"), null);
});

test("github asset counts raise the total without double counting site clicks", () => {
  const same = mergeView({ windows: 2, macos: 1 }, 3);
  assert.equal(same.total, 3);
  assert.equal(same.githubOnly, 0);
  const extra = mergeView({ windows: 2 }, 10);
  assert.equal(extra.githubOnly, 8);
  assert.equal(extra.total, 10);
  const ahead = mergeView({ linux: 4 }, 1);
  assert.equal(ahead.total, 4);
  assert.equal(ahead.githubOnly, 0);
});

test("clicks persist, split by device, and ignore a second click inside the rate window", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rx-counts-"));
  const db = openSqlite(join(dir, "c.sqlite"));
  await ensureSchema(db);
  const first = await recordHit(db, { ip: "203.0.113.5", href: storeHref, ua: "Windows NT 10.0", now: 1_000_000 });
  assert.equal(first.counted, true);
  assert.equal(first.counts.windows, 1);
  assert.equal(first.total, 1);
  const chip = await recordHit(db, { ip: "203.0.113.5", href: chipHref, ua: "Macintosh", now: 1_000_500 });
  assert.equal(chip.limited, true);
  assert.equal(chip.counts.windows, 1);
  assert.equal(chip.counts.macos, 0);
  const later = await recordHit(db, { ip: "203.0.113.5", href: chipHref, ua: "Macintosh", now: 1_020_000 });
  assert.equal(later.counted, true);
  assert.equal(later.counts.macos, 1);
  assert.equal(later.total, 2);
  const again = openSqlite(join(dir, "c.sqlite"));
  await ensureSchema(again);
  const saved = await readMany(again, [storeHref], { now: 1_020_000, fetchImpl: async () => { throw new Error("no network"); } });
  assert.equal(saved.items[0].counts.windows, 1);
  assert.equal(saved.items[0].counts.macos, 1);
  assert.equal(saved.items[0].total, 2);
  await rm(dir, { recursive: true, force: true });
});

test("parallel connections increment the same counter without losing clicks", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rx-parallel-"));
  const file = join(dir, "c.sqlite");
  const setup = openSqlite(file);
  await ensureSchema(setup);
  const workers = 8;
  const each = 25;
  const results = await Promise.all(Array.from({ length: workers }, (_, index) => new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./increment-worker.mjs", import.meta.url), {
      workerData: {
        db: file,
        n: each,
        ip: `198.51.100.${index + 1}`,
        href: storeHref,
        ua: index % 2 === 0 ? "Windows NT 10.0" : "X11; Linux x86_64",
      },
    });
    worker.on("message", resolve);
    worker.on("error", reject);
  })));
  const counted = results.reduce((sum, entry) => sum + entry.counted, 0);
  assert.equal(counted, workers * each);
  const check = openSqlite(file);
  const view = await readMany(check, [storeHref], { now: 2_000_000_000_000, fetchImpl: async () => { throw new Error("no network"); } });
  assert.equal(view.items[0].total, workers * each);
  assert.equal(view.items[0].counts.windows + view.items[0].counts.linux, workers * each);
  await rm(dir, { recursive: true, force: true });
});

test("github download_count is merged into the total", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rx-gh-"));
  const db = openSqlite(join(dir, "c.sqlite"));
  await ensureSchema(db);
  const fetchImpl = async () => ({
    ok: true,
    async json() {
      return { assets: [{ name: "Vortex-2.8-mac.dmg", download_count: 40 }] };
    },
  });
  await recordHit(db, { ip: "203.0.113.9", href: githubHref, ua: "Macintosh", now: 5_000 });
  const view = await readMany(db, [githubHref], { now: 5_000, fetchImpl });
  assert.equal(view.items[0].counts.macos, 1);
  assert.equal(view.items[0].github, 40);
  assert.equal(view.items[0].githubOnly, 39);
  assert.equal(view.items[0].total, 40);
  await rm(dir, { recursive: true, force: true });
});

test("the http api records the caller device and keeps the count after a new process", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rx-http-"));
  const file = join(dir, "c.sqlite");
  const child = startServer(file);
  try {
    const port = await child.port;
    const base = `http://127.0.0.1:${port}`;
    const hit = (ua, ip, href) => fetch(`${base}/__downloads/hit`, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": ua, "x-forwarded-for": ip },
      body: JSON.stringify({ href }),
    }).then((res) => res.json());
    const mac = await hit("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", "203.0.113.20", storeHref);
    assert.equal(mac.platform, "macos");
    assert.equal(mac.counts.macos, 1);
    assert.equal(mac.total, 1);
    const spam = await hit("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", "203.0.113.20", storeHref);
    assert.equal(spam.limited, true);
    assert.equal(spam.total, 1);
    const windows = await Promise.all(Array.from({ length: 20 }, (_, i) =>
      hit("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", `203.0.113.${30 + i}`, "/api/store/download/rotten-core/windows-amd64")));
    assert.equal(windows.filter((row) => row.counted).length, 20);
    const listed = await fetch(`${base}/__downloads/counts?href=${encodeURIComponent("/api/store/download/rotten-core/windows-amd64")}`).then((res) => res.json());
    assert.equal(listed.items[0].counts.windows, 20);
    assert.equal(listed.items[0].total, 20);
  } finally {
    child.kill();
    await rm(dir, { recursive: true, force: true });
  }
});

function startServer(file) {
  const child = spawn(process.execPath, ["src/server.mjs"], {
    cwd: root,
    env: { ...process.env, PORT: "0", COUNTS_DB: file, COUNT_TRUST_PROXY: "1", COUNT_WINDOW_SEC: "15" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let buffer = "";
  const port = new Promise((resolve, reject) => {
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/127\.0\.0\.1:(\d+)/);
      if (match) resolve(Number(match[1]));
    });
    child.stderr.on("data", (chunk) => {
      buffer += chunk.toString();
    });
    child.on("exit", (code) => {
      if (code) reject(new Error(`server exited ${code}: ${buffer}`));
    });
  });
  return { port, kill: () => child.kill() };
}
