import { SCHEMA } from "./schema.mjs";
import { itemFromHref, mergeView, platformFromUA } from "./platform.mjs";

export const WINDOW_SEC = 15;
export const GH_TTL_MS = 10 * 60 * 1000;

export async function ensureSchema(db) {
  await db.exec(SCHEMA);
}

export async function recordHit(db, { ip, href, ua, now = Date.now(), windowSec = WINDOW_SEC }) {
  const item = itemFromHref(href);
  if (!item) return { error: "unknown_download", status: 400 };
  const platform = platformFromUA(ua);
  const bucket = Math.floor(now / 1000 / windowSec);
  // The rate-limit insert is the lock: ON CONFLICT means this IP already
  // counted this item in the current window. The counter update is
  // `n = n + 1`, which SQLite applies atomically. Both statements run in one
  // transaction on the local database. D1 runs the insert as its own
  // committed statement, so a second request cannot pass the same gate.
  const counted = await db.transaction(async (tx) => {
    await tx.run(
      `INSERT INTO items (id, kind, href, gh_owner, gh_repo, gh_tag, gh_file)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET href = excluded.href`,
      [item.id, item.kind, item.href, item.gh_owner || null, item.gh_repo || null, item.gh_tag || null, item.gh_file || null],
    );
    const gate = await tx.run(
      `INSERT INTO rl (ip, item, bucket) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`,
      [ip, item.id, bucket],
    );
    if ((gate.changes || 0) === 0) return false;
    await tx.run(
      `INSERT INTO counts (item, platform, n) VALUES (?, ?, 1)
       ON CONFLICT(item, platform) DO UPDATE SET n = counts.n + 1`,
      [item.id, platform],
    );
    await tx.run(`DELETE FROM rl WHERE bucket < ?`, [bucket - 240]);
    return true;
  });
  const view = await readItem(db, item.id);
  return {
    id: item.id,
    href: item.href,
    platform,
    counted,
    limited: !counted,
    ...view,
  };
}

export async function readMany(db, hrefs, { now = Date.now(), fetchImpl = fetch, githubToken = "", ttl = GH_TTL_MS } = {}) {
  const items = [];
  for (const href of hrefs) {
    const parsed = itemFromHref(href);
    if (!parsed) continue;
    await db.run(
      `INSERT INTO items (id, kind, href, gh_owner, gh_repo, gh_tag, gh_file)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET href = excluded.href`,
      [parsed.id, parsed.kind, parsed.href, parsed.gh_owner || null, parsed.gh_repo || null, parsed.gh_tag || null, parsed.gh_file || null],
    );
    if (parsed.kind === "github") await refreshGithub(db, parsed, { now, fetchImpl, githubToken, ttl });
    items.push({ ...(await readItem(db, parsed.id)), id: parsed.id, href: parsed.href });
  }
  return { items };
}

async function readItem(db, id) {
  const rows = await db.all(`SELECT platform, n FROM counts WHERE item = ?`, [id]);
  const counts = {};
  for (const row of rows) counts[row.platform] = row.n;
  const meta = await db.get(`SELECT kind, gh_owner, gh_repo, gh_tag, gh_file FROM items WHERE id = ?`, [id]);
  let github = null;
  if (meta?.kind === "github") {
    const cached = await db.get(`SELECT download_count FROM gh WHERE item = ?`, [id]);
    if (cached) github = cached.download_count;
  }
  return mergeView(counts, github);
}

async function refreshGithub(db, item, { now, fetchImpl, githubToken, ttl }) {
  const cached = await db.get(`SELECT download_count, fetched_at FROM gh WHERE item = ?`, [item.id]);
  if (cached && now - cached.fetched_at < ttl) return;
  const url = `https://api.github.com/repos/${encodeURIComponent(item.gh_owner)}/${encodeURIComponent(item.gh_repo)}/releases/tags/${encodeURIComponent(item.gh_tag)}`;
  const headers = {
    accept: "application/vnd.github+json",
    "user-agent": "red-xai-download-counts",
  };
  if (githubToken) headers.authorization = `Bearer ${githubToken}`;
  let body;
  try {
    const res = await fetchImpl(url, { headers });
    if (!res.ok) return;
    body = await res.json();
  } catch {
    return;
  }
  const assets = Array.isArray(body?.assets) ? body.assets : [];
  const asset = assets.find((entry) => entry?.name === item.gh_file);
  if (!asset || typeof asset.download_count !== "number") return;
  await db.run(
    `INSERT INTO gh (item, download_count, fetched_at) VALUES (?, ?, ?)
     ON CONFLICT(item) DO UPDATE SET download_count = excluded.download_count, fetched_at = excluded.fetched_at`,
    [item.id, asset.download_count, now],
  );
}
