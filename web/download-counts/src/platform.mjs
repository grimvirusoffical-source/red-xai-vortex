import { PLATFORMS } from "./schema.mjs";

// Device of the visitor who clicked, from the User-Agent. Order matters:
// iOS and Android both mention other desktop tokens.
export function platformFromUA(ua) {
  const s = String(ua || "");
  if (/iPad|iPhone|iPod/i.test(s) || (/Macintosh/i.test(s) && /Mobile/i.test(s))) return "ios";
  if (/Android/i.test(s)) return "android";
  if (/Windows/i.test(s)) return "windows";
  if (/Macintosh|Mac OS X/i.test(s)) return "macos";
  if (/Linux|X11/i.test(s)) return "linux";
  return "other";
}

export function itemFromHref(href) {
  let url;
  try {
    url = new URL(String(href || ""), "https://red-xai.com");
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.pathname.length > 500) return null;

  const store = url.pathname.match(/^\/api\/store\/download\/([^/]+)\/([^/]+)\/?$/);
  if (store) {
    const app = safeName(decodeURIComponent(store[1]));
    if (!app) return null;
    return { id: `store:${app}`, kind: "store", href: url.href, app };
  }

  const gh = url.hostname === "github.com"
    ? url.pathname.match(/^\/([^/]+)\/([^/]+)\/releases\/download\/([^/]+)\/([^/]+)$/)
    : null;
  if (gh) {
    const owner = safeName(gh[1]);
    const repo = safeName(gh[2]);
    const tag = safeName(decodeURIComponent(gh[3]));
    const file = safeName(decodeURIComponent(gh[4]));
    if (!owner || !repo || !tag || !file) return null;
    return {
      id: `github:${owner}/${repo}/${tag}/${file}`,
      kind: "github",
      href: url.href,
      gh_owner: owner,
      gh_repo: repo,
      gh_tag: tag,
      gh_file: file,
    };
  }

  const file = url.pathname.split("/").pop() || "";
  if (url.pathname.startsWith("/vortex/download/") && file && file !== "download") {
    const name = safeName(decodeURIComponent(file));
    if (!name) return null;
    return { id: `vortex:${name}`, kind: "file", href: url.href };
  }

  return null;
}

function safeName(value) {
  const s = String(value || "");
  if (!s || s.length > 180) return "";
  if (/[\u0000-\u001f]/.test(s)) return "";
  return s;
}

export function emptyCounts() {
  return Object.fromEntries(PLATFORMS.map((p) => [p, 0]));
}

// GitHub's asset download_count is not split by device. Treat it as a floor
// so clicks we recorded and downloads GitHub recorded are not added twice:
// when a click lands on the GitHub asset, both numbers move together.
export function mergeView(counts, githubCount) {
  const devices = emptyCounts();
  for (const key of PLATFORMS) devices[key] = Number(counts?.[key] || 0);
  const local = PLATFORMS.reduce((sum, key) => sum + devices[key], 0);
  const github = githubCount == null ? null : Number(githubCount);
  const githubOnly = github == null ? 0 : Math.max(0, github - local);
  return { counts: devices, github, githubOnly, total: local + githubOnly };
}
