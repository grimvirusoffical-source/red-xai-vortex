# Download counts for red-xai.com

Live per-download counters for every Download button: a device breakdown (Windows, macOS, Linux, Android, iOS) plus the total. A click adds one to the clicking device, taken from the User-Agent, and to the total. Counts are stored on the server, shared by every visitor, and a 15 second per-IP limit drops repeat clicks on the same item.

## What actually serves red-xai.com

This repository (`red-xai-vortex`) does **not** serve https://red-xai.com. It is the Vortex app, gateway, and the Cloud PC process. That process is what answers on the Vultr host linked from the site (`/vortex/`), including the public installer page at `/vortex/download/`. The HTML for that page is deployed on the server under `CPC_WWW` (default `/srv/cloudpc-web/www`) and is not in git.

https://red-xai.com is a Cloudflare Tunnel (`redx`) to `127.0.0.1:4200` on the origin (exact `/` is a separate redirect on port 4210). The pages are a React app with an oRPC API at `/api/rpc`. The UI matches `grimvirusoffical-source/Red-XAIHost-8612` branch `host-integration` (same panel copy, same port, same oRPC layout) plus Rotten Store, news, and Red-XAI accounts. Those additions are not in any public branch. `grimvirusoffical-source/red-xai-accounts` is not a repository this token can see (GitHub returns 404).

Download controls on the live site:

- Rotten Store: `Download for {device}` and the platform chips, both `GET /api/store/download/{app}/{platform}`. Every platform of one app shares one counter.
- Builds: a `Download` link to a release artifact. GitHub release asset URLs are their own counter.

Because that UI source is not in a repo this workspace can edit, the counter is a small script plus an API. A Cloudflare Worker in front of the tunnel injects the script into HTML responses. The same API runs locally for tests and the demo.

## Local demo

```bash
cd web/download-counts
npm install
npm test
npm start
```

Open http://127.0.0.1:8787/. The page uses the same button structure as the live store and builds list. `COUNTS_DB` chooses the SQLite file (default `counts.sqlite` in this directory). `COUNT_WINDOW_SEC` changes the per-IP window (default 15). `COUNT_TRUST_PROXY=1` trusts `X-Forwarded-For`, which the tests use. The Worker ignores that header and uses `CF-Connecting-IP`.

`GET /fixture` is the second page the browser test clicks: a store button, a platform chip, and a flex-row GitHub Download button.

## API

- `POST /__downloads/hit` with JSON `{ "href" }`. The server decides the item from the href and the device from the User-Agent. A repeat from the same IP and item inside the window returns the current counts with `limited: true` and does not add another click. The browser still follows the link.
- `GET /__downloads/counts?href=...` returns the same numbers. Repeat `href` for each button.
- `GET /__downloads/widget.js` is the script that inserts a counter directly under each control whose label starts with "Download". Platform chips count toward the same app and do not get a second counter. A horizontal button row gets the counter under the row.

GitHub release asset links optionally merge `download_count` from `GET /repos/{owner}/{repo}/releases/tags/{tag}`. The total is the higher of the clicks recorded here and GitHub's asset count, so a click that GitHub also counts is not added twice. The difference is shown as "GitHub releases" when GitHub is ahead. Set `GITHUB_TOKEN` to raise the API rate limit. The lookup is cached for 10 minutes. If GitHub is unreachable, the device counts still stand.

A click is two statements inside one transaction on the local database. The first is `INSERT INTO rl ... ON CONFLICT DO NOTHING`. Only the caller that inserts the rate-limit row runs `UPDATE n = n + 1`. SQLite applies that update atomically, and `busy_timeout` makes other processes wait instead of failing. D1 commits each statement on its own; the rate-limit insert is still the gate, so two overlapping requests cannot both increment.

## Deploy on Cloudflare

The account already proxies red-xai.com. Do this once, from `web/download-counts`:

```bash
npx wrangler d1 create redx-download-counts
```

Put the printed database id in `wrangler.jsonc` (`d1_databases[0].database_id`), then:

```bash
npx wrangler d1 migrations apply redx-download-counts --remote
npx wrangler secret put GITHUB_TOKEN   # optional
npx wrangler deploy
```

Attach the worker to `red-xai.com/*` and `www.red-xai.com/*` (Workers → route, or `wrangler` routes). It forwards every other request to the tunnel with `redirect: "manual"` and appends `<script src="/__downloads/widget.js" defer>` to HTML bodies. `/__downloads/*` is answered by the worker. The tables are also created on the first request if the migration was skipped.

`COUNT_WINDOW_SEC` can be set with `wrangler secret` or a var if you want a different limit. Leave it unset for 15 seconds.

No new env vars are required on the Vortex / Cloud PC host. This does not change the unpublished panel source. When that source is in git, the same widget can be loaded from the app instead of injected.
