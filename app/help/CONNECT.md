# Connect any app

Red-XAI Vortex speaks the **OpenAI** API and the **Ollama** API. Every model is reachable the same way:

| Model id | What it is |
|---|---|
| any installed id (e.g. `qwen2.5-coder-14b`) | a local model |
| `vortex` / `vortex-vN` (alias `red-xai`) | the learning model, with memory and routing |
| `redx-merge-<name>` | a saved merge (Draft + Refine, Panel + Judge, Router) |
| `ext-<provider>-<model>` | an outside OpenAI-compatible provider |
| Modelfile aliases | your `FROM`/`SYSTEM`/`PARAMETER` presets |

Create a key in **API Keys**: `redx_ai_…` (chat models), or `redx_xai_…` with scopes (`chat`, `image`, `audio`, `embeddings`, `train:submit`).
`BASE` below is your public URL (e.g. `https://YOUR_DOMAIN`) or `http://127.0.0.1:18091` over the SSH tunnel.

## OpenAI-style apps (ChatGPT-style clients, SDKs, IDE plugins)
- Base URL: `BASE/v1`
- API key: your `redx_…` key
- Model: any id from `GET BASE/v1/models`

```python
from openai import OpenAI
c = OpenAI(base_url="https://YOUR_DOMAIN/v1", api_key="redx_ai_…")
print(c.chat.completions.create(model="vortex", messages=[{"role":"user","content":"hi"}]).choices[0].message.content)
```
Works with Open WebUI, LibreChat, Continue, Cursor/VS Code "OpenAI-compatible" settings, LangChain, LlamaIndex, n8n, etc.

## Ollama-style apps
- Base URL: `BASE` (no `/v1`)
- Endpoints: `/api/tags`, `/api/show`, `/api/chat`, `/api/generate`, `/api/embed`, `/api/embeddings`, `/api/version`
- The client must send `Authorization: Bearer redx_…`. Open WebUI, Continue and most libraries let you add headers. Apps that can't send headers can't connect directly; use their OpenAI mode instead.

```bash
curl BASE/api/chat -H "Authorization: Bearer redx_ai_…" -d '{"model":"vortex","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## Custom GPT Actions (ChatGPT)
1. You need the public HTTPS URL (see [PUBLIC-ACCESS.md](PUBLIC-ACCESS.md)); Actions can't reach an SSH tunnel.
2. In the GPT editor → **Actions** → **Import**, paste [`openapi-gpt-actions.yaml`](openapi-gpt-actions.yaml) after replacing `YOUR_DOMAIN`.
3. **Authentication**: API Key → **Bearer** → paste a `redx_xai_…` key limited to the scopes you want.
4. Operations: `askModel` (any model, merge or Vortex), `listModels`, `generateImage`, `generateAudio`, `teachVortex`.
5. Add a privacy-policy URL (required by ChatGPT for public GPTs).

## Feeding Vortex from other apps
- `POST /v1/redxai/ingest` (scope `train:submit`): add documents to Vortex's memory.
- `POST /v1/redxai/feedback` (scope `train:submit`, `consent:true`): ratings and corrections.
- Send `X-Vortex-Train: 1` on chat requests to let Vortex learn from that model's replies (only when the owner has learning on).
