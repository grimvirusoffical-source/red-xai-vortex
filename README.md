# Red-XAI Vortex

Run open models on your own server, chat with them from a native Mac app, and plug them into
any app that speaks the **OpenAI** or **Ollama** API, using your own API keys.

```
 Red-XAI Vortex (Mac app) ──SSH tunnel──▶ dolphin-gateway :8092 (admin)      ┐
 Other apps (OpenAI / Ollama clients) ──▶ dolphin-gateway :8091 (keys)    ├─▶ llama.cpp router :8090 ─▶ GGUF models
                                                   └─▶ outside providers (OpenAI-compatible)  ┘
```

## Components

| Path | What it is | Status |
|---|---|---|
| `app/` | **Red-XAI Vortex**, native SwiftUI chat app for macOS 14+ | ✅ |
| `app/…/WebBrowser.swift` | Local model browser at `http://127.0.0.1:<port>/?t=<token>`, Ollama-library style | ✅ |
| `gateway/` | **dolphin-gateway** (Go): OpenAI + Ollama APIs, per-app keys, rate limits, merges, outside providers, Red-XAI, admin API | ✅ |
| `server/dolphin-models` | Model manager: curated catalog, the Ollama library, Modelfile aliases, pull/remove with disk and RAM checks | ✅ |
| `server/install.sh` | One-shot server installer, also run by the app's Servers → Install | ✅ Linux / WSL2 |
| Servers screen | Several servers, one-click install over SSH, automatic failover to another server or this Mac | ✅ |
| Local mode | llama.cpp with Metal on the Mac, started on demand and stopped when idle or on quit | ✅ |
| **Vortex** (model `vortex`) | The learning model: memory (RAG), learns from the active model (distillation), training mode, crawler, preloaded open datasets, scoped keys, versioned LoRA adapters, benchmark | ✅ chat/memory/capture/scoring/keys/crawler · 🚧 LoRA training needs a GPU |
| Overflow storage | Sealed training data moved to S3-compatible or WebDAV storage at 80% disk | ✅ S3 + WebDAV · ⛔ TeraBox (needs an approved Open Platform app) |
| PC control | Opt-in local agent, off by default, confirms every action | 📋 planned |
| Vortex image / audio | stable-diffusion.cpp (SD-Turbo) and MusicGen-small on CPU | ✅ ~15 s per 512² image, ~18 s per 5 s clip on 16 vCPU |
| Windows and Linux client apps | | 📋 planned. Use any OpenAI/Ollama client meanwhile |

## Features

- **Model library**: download, uninstall (frees disk) and set a default from the app, with size, RAM needed and expected speed per model; disk and RAM checks before each download.
- **Your own API keys**: `redx_ai_…` keys per app, each with a name, allowed models, requests/min, usage counts and last-used time, and a revoke button. The plaintext is shown once and stored only as an HMAC hash.
- **Merges**: several models answer as one virtual model, `redx-merge-<name>`.
  - *Draft + Refine*: a fast model drafts and a bigger one polishes.
  - *Panel + Judge*: 2–3 models answer and a judge picks or synthesizes the best.
  - *Router*: picks the coder for code, the reasoner for logic, and general for everything else.
- **Outside providers**: add any OpenAI-compatible base URL and key (OpenAI, Groq, OpenRouter, Together, Mistral, Gemini, Anthropic-compatible…) with your own display names. Provider keys are sealed server-side, and their models work with your keys and inside merges.
- **Ollama compatible**: browse and pull the whole ollama.com library onto llama.cpp, use Modelfile aliases (`FROM`/`SYSTEM`/`PARAMETER`), and call `/api/chat`, `/api/generate`, `/api/tags` and `/api/embed`.
- **Model browser**: a local web page (search, categories, tags and quantizations, download target, progress, Remove, Add to Merge), guarded by a per-session token.
- **Vortex**: your own learning model. It learns from whichever model you chat with, keeps a memory preloaded with open datasets, and can make images and music. See [docs/VORTEX.md](docs/VORTEX.md).
- **Connect anything**: OpenAI-style apps, Ollama-style apps and custom GPT Actions (OpenAPI schema included). See [docs/CONNECT.md](docs/CONNECT.md).
- **Replies only when finished** (optional), personas, themes, chat export, training-data export.

## Quick start

### 1. Server (Linux, recommended: Ubuntu 24.04, 8+ cores, 16–32 GB RAM)
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/grimvirusoffical-source/red-xai-vortex/main/server/install.sh)"
```
See [docs/SERVER-LINUX.md](docs/SERVER-LINUX.md), [docs/SERVER-WINDOWS.md](docs/SERVER-WINDOWS.md) (WSL2) and [docs/SERVER-MAC.md](docs/SERVER-MAC.md).

### 2. Mac app
```bash
cd app && ./build.sh            # ad-hoc signed; set SIGN_ID to sign with your Developer ID
cp -R "build/Red-XAI Vortex.app" /Applications/
```
Then open Settings → Connection, set the SSH host (`root@YOUR_SERVER`), and paste the admin key
from `/root/dolphino-admin.key` on the server. See [docs/MAC-APP.md](docs/MAC-APP.md).

### 3. Other apps
Create a key under **Library, Merges & Keys → API Keys**, then point any OpenAI client at
`https://YOUR_DOMAIN/v1` (or `http://127.0.0.1:18091/v1` through an SSH tunnel). See [docs/API.md](docs/API.md).

## Docs
- **[Complete guide (start here)](docs/USER-GUIDE.md)** · [Troubleshooting](docs/TROUBLESHOOTING.md) · [FAQ](docs/FAQ.md)
- [Merging models (with diagrams)](docs/MERGES.md)
- [Servers, failover, pooling and nodes](docs/POOLING.md)
- [Owner vs user permissions](docs/PERMISSIONS.md)
- [API reference (OpenAI + Ollama + admin)](docs/API.md)
- [Outside providers](docs/PROVIDERS.md)
- [Gateway build & crypto backends](docs/GATEWAY.md)
- [Vortex, the learning model](docs/VORTEX.md)
- [Connect apps (OpenAI, Ollama, GPT Actions)](docs/CONNECT.md) · [OpenAPI schema](docs/openapi-gpt-actions.yaml)
- [Overflow storage](docs/STORAGE.md)
- [PC control (planned)](docs/PC-CONTROL.md)
- [Model browser](docs/MODEL-BROWSER.md)
- [Exposing the gateway publicly (Cloudflare Tunnel / reverse proxy)](docs/PUBLIC-ACCESS.md)

## License
MIT. Model weights keep their own licenses, which are listed per model in the catalog.
