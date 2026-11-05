(() => {
  if (window.__rxDownloadCounts) return;
  window.__rxDownloadCounts = true;

  const LABELS = [
    ["windows", "Windows"],
    ["macos", "macOS"],
    ["linux", "Linux"],
    ["android", "Android"],
    ["ios", "iOS"],
  ];

  const style = document.createElement("style");
  style.textContent = `
    .rx-counts{margin:8px 0 0;display:grid;gap:2px;width:100%;font:500 12px/1.45 "IBM Plex Sans",var(--font-sans,inherit),system-ui,sans-serif;color:#8a9099}
    .rx-counts .rx-row{display:flex;justify-content:space-between;gap:16px}
    .rx-counts .num{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums;color:#f2f4f7}
    .rx-counts .rx-total{margin-top:4px;padding-top:4px;border-top:1px solid #23262d;color:#f2f4f7;font-weight:600}
    .rx-counts .rx-note{font-weight:500;color:#8a9099}
  `;
  document.head.appendChild(style);

  const panels = new Map();

  function labelOf(el) {
    return (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
  }

  function isDownloadControl(el) {
    if (!el || (el.tagName !== "A" && el.tagName !== "BUTTON")) return false;
    const href = el.getAttribute("href") || "";
    if (/\/api\/store\/download\/[^/]+\/[^/]+\/?$/.test(href)) return true;
    if (/github\.com\/[^/]+\/[^/]+\/releases\/download\//.test(el.href || href)) return true;
    if (/\/vortex\/download\/[^/]+$/.test(href)) return true;
    return /^Download\b/i.test(labelOf(el));
  }

  function showsPanel(el) {
    return /^Download\b/i.test(labelOf(el));
  }

  function hrefOf(el) {
    return el.href || el.getAttribute("href") || "";
  }

  function placePanel(el) {
    if (el.dataset.rxCount === "1" || !showsPanel(el)) return;
    const parent = el.parentElement;
    let after = el;
    if (parent) {
      const display = getComputedStyle(parent).display;
      const direction = getComputedStyle(parent).flexDirection || "row";
      if ((display === "flex" || display === "inline-flex") && direction.startsWith("row")) after = parent;
    }
    const panel = document.createElement("div");
    panel.className = "rx-counts";
    panel.dataset.rxPanel = hrefOf(el);
    panel.setAttribute("role", "status");
    panel.setAttribute("aria-live", "polite");
    after.insertAdjacentElement("afterend", panel);
    el.dataset.rxCount = "1";
    panels.set(hrefOf(el), panel);
    render(panel, null);
  }

  function render(panel, view) {
    const counts = view?.counts || {};
    const rows = LABELS.map(([key, label]) => row(label, counts[key] || 0));
    if ((counts.other || 0) > 0) rows.push(row("Other", counts.other));
    if ((view?.githubOnly || 0) > 0) rows.push(row("GitHub releases", view.githubOnly, "rx-note"));
    const total = view?.total || 0;
    panel.innerHTML = `${rows.join("")}<div class="rx-row rx-total"><span>Total</span><span class="num">${total}</span></div>`;
  }

  function row(label, value, extra = "") {
    return `<div class="rx-row ${extra}"><span>${label}</span><span class="num">${value}</span></div>`;
  }

  function scan() {
    document.querySelectorAll("a, button").forEach((el) => {
      if (isDownloadControl(el)) placePanel(el);
    });
  }

  async function refresh() {
    const hrefs = [...panels.keys()];
    if (!hrefs.length) return;
    const query = hrefs.map((href) => `href=${encodeURIComponent(href)}`).join("&");
    const res = await fetch(`/__downloads/counts?${query}`, { credentials: "same-origin", cache: "no-store" });
    if (!res.ok) return;
    const body = await res.json();
    for (const item of body.items || []) {
      const panel = panels.get(item.href);
      if (panel) render(panel, item);
    }
  }

  document.addEventListener("click", (event) => {
    const el = event.target?.closest?.("a, button");
    if (!el || !isDownloadControl(el)) return;
    const href = hrefOf(el);
    fetch("/__downloads/hit", {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ href }),
    })
      .then((res) => res.json())
      .then((body) => {
        if (!body || !body.href) return;
        const panel = panels.get(body.href) || [...panels.entries()].find(([key]) => key.split("#")[0] === body.href.split("#")[0])?.[1];
        if (panel) render(panel, body);
        else refresh();
      })
      .catch(() => {});
  }, true);

  const observer = new MutationObserver(() => scan());
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();
  refresh();
  setInterval(refresh, 4000);
})();
