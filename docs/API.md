# API reference

Every request needs `Authorization: Bearer redx_ai_…` (or `x-api-key`). The public port is 8091.

## OpenAI-compatible (`/v1`)
| Method | Path | Notes |
|---|---|---|
| GET | `/v1/models` | Local models, `ext-…` provider models and `redx-merge-…` merges allowed for the key |
| POST | `/v1/chat/completions` | `stream` supported. Merges return one final chunk |
| POST | `/v1/completions` | Local models |
| POST | `/v1/embeddings` | For example `nomic-embed-v1.5` |

```bash
curl https://YOUR_DOMAIN/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-coder-14b","messages":[{"role":"user","content":"hello"}]}'
```

## Ollama-compatible (`/api`)
`GET /api/tags`, `GET /api/version`, `POST /api/chat`, `POST /api/generate`, `POST /api/embed`, `POST /api/embeddings`, `POST /api/show`.
Streaming is NDJSON as in Ollama. Point Ollama clients at `https://YOUR_DOMAIN` and set the key header.

## Red-XAI
| Method | Path | Scope | |
|---|---|---|---|
| POST | `/v1/chat/completions` with `"model":"red-xai"` (or `red-xai-v2`) | chat | persona + knowledge + capability routing. The `X-RedXAI-Route` header shows the route |
| GET | `/v1/redxai/info` | – | versions, knowledge size, capabilities |
| GET | `/v1/redxai/search?q=` | chat | top knowledge chunks |
| POST | `/v1/redxai/ingest` `{"documents":[{"text","source"}]}` | train:submit | chunk, embed and store (deduped) |
| POST | `/v1/redxai/feedback` `{"consent":true,"messages","response","rating":1\|-1,"correction"}` | train:submit | PII-scrubbed, stored sealed |
| POST | `/v1/images/generations` `{"prompt","size":"512x512","steps":4}` | image | returns `b64_json` (PNG) |
| POST | `/v1/audio/generations` `{"prompt","duration":8}` | audio | returns `b64_audio` (WAV) |

Key types: `redx_ai_…` keys have every scope. `redx_xai_…` keys only have the scopes you give them (`chat`, `image`, `audio`, `embeddings`, `train:submit`).

## Limits
Each key has its own requests per minute (default 60), and the HTTP status is 429 with `Retry-After` when exceeded. `max_tokens` is capped at 4096 and bodies at 4 MB. One local generation runs at a time; others queue. A memory guard unloads models so the next one fits.

## Errors
`401` missing/invalid/revoked key · `403` model not allowed for key · `404` unknown model · `429` rate limited · `502` model server/provider unavailable.

## Admin API (port 8092, localhost only, admin key)
| Method | Path | |
|---|---|---|
| GET | `/admin/models`, `/admin/catalog`, `/admin/jobs` | installed / catalog / download progress |
| POST | `/admin/models/pull` `{"id"}` | start a download |
| DELETE | `/admin/models/{id}` | uninstall (returns `freed_bytes`) |
| POST | `/admin/default` `{"id"}` | |
| GET/POST | `/admin/keys` `{"name","models":[],"rpm"}` | POST returns the plaintext key once |
| DELETE | `/admin/keys/{id}` | revoke |
| GET/POST | `/admin/merges`; DELETE `/admin/merges/{name}` | |
| GET/POST | `/admin/providers`; DELETE `/admin/providers/{id}`; POST `/admin/providers/{id}/test` | |
| GET/POST | `/admin/ollama/library`, `/admin/ollama/tags?name=`, `/admin/ollama/pull` `{"ref":"qwen2.5:7b"}` | |
| GET/POST/DELETE | `/admin/aliases` `{"name","modelfile"}` | Ollama-style Modelfile |
| GET/POST | `/admin/redxai/config`, `/admin/redxai/stats`, `/admin/redxai/crawl-config` | |
| POST | `/admin/redxai/crawl`, `/admin/redxai/eval`, `/admin/redxai/export` | |
| DELETE | `/admin/redxai/kb?source=<src or prefix*>` | forget knowledge |
The admin port also serves `/v1/*` and `/api/*` for the app.
