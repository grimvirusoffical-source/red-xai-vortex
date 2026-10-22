# Integrations: connect your tools to Vortex

**Where:** Library, Merges & Keys → **Integrations**.

Each card is one tool. Pick a model (`vortex`, any server or local model, a `redx-merge-…` or an `ext-…` provider model) and press **Connect**:

- A **dedicated API key** is created for that tool (`integration: <tool>`), saved in your Keychain, and never shown on screen.
- **Automatic** cards write the tool's own official config file. The original is **backed up first** (Application Support/Red-XAI Vortex/integration-backups/).
- **Guided** cards put the key on your clipboard and show the exact steps for that app's settings screen.
- The card then shows a label such as **"Codex: vortex"** or **"Claude Code: qwen2.5-coder-14b"** and a **Disconnect** button. Disconnect restores the backed-up config (or deletes a file that didn't exist before) and revokes the key.

Tools on this Mac use `http://127.0.0.1:18091` (the app's SSH tunnel, so the app must be open). Tools that call from their own cloud (Cursor, n8n Cloud, Flowise Cloud, Custom GPTs) need your **public https URL** ([PUBLIC-ACCESS.md](PUBLIC-ACCESS.md)).

## How each protocol is served
| Tool speaks | Gateway endpoint |
|---|---|
| OpenAI Chat Completions | `/v1/chat/completions` |
| OpenAI Responses (Codex) | `/v1/responses` (shim) |
| Anthropic Messages (Claude Code) | `/v1/messages` (shim, accepts `x-api-key`) |
| Gemini API (Gemini CLI) | `/v1beta/models/{model}:generateContent` / `:streamGenerateContent` (shim, accepts `x-goog-api-key`) |
| Ollama | `/api/chat`, `/api/generate`, `/api/tags` |

The shims translate to chat completions, so merges, Vortex memory, providers, key limits and learning all apply. Tool calls are translated both ways. Some local models (e.g. Qwen2.5-Coder) write tool calls as tagged text; the gateway converts those into real tool calls.
Streaming in the shims sends the finished answer as one stream (it doesn't type it out word by word).

## The tools


### Coding agents
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| OpenAI Codex CLI | automatic | OpenAI Responses | ~/.codex/vortex.config.toml (Codex 0.163+ profile file). Run: codex --profile vortex |
| Claude Code | automatic | Anthropic Messages | ~/.claude/settings.json → env: ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL (gateway /v1/messages shim) |
| Gemini CLI | automatic | Gemini API | ~/.gemini/.env: GOOGLE_GEMINI_BASE_URL + GEMINI_API_KEY + GEMINI_MODEL (gateway /v1beta Gemini shim). Run: gemini |
| OpenCode | automatic | OpenAI Chat | ~/.config/opencode/opencode.json → provider "vortex" (@ai-sdk/openai-compatible, baseURL, apiKey {env:VORTEX_API_KEY}) |
| Grok CLI (open-source) | automatic | OpenAI Chat | ~/.grok/user-settings.json → baseURL, apiKey, defaultModel |
| Aider | automatic | OpenAI Chat | ~/.aider.conf.yml → openai-api-base, openai-api-key, model openai/<model> (only if you have no aider config yet) |

### Editors
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| VS Code / JetBrains: Continue | automatic | OpenAI Chat | ~/.continue/config.yaml → model with provider openai + apiBase (only if you have no Continue config yet) |

### Desktop chat
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| Raycast AI | automatic | OpenAI Chat | ~/.config/raycast/ai/providers.yaml (Custom Providers) (only if you have no providers.yaml yet) |

### Editors
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| Cursor | guided | OpenAI Chat | Cursor → Settings → Models → API Keys → OpenAI: paste the key, turn on Override OpenAI Base URL = `BASE/v1`, then add model `MODEL`. **Needs the public URL.** |
| Cline | guided | OpenAI Chat | Cline settings → API Provider: OpenAI Compatible → Base URL `BASE/v1`, API Key: paste, Model ID `MODEL`. |
| Roo Code | guided | OpenAI Chat | Roo Code settings → API Provider: OpenAI Compatible → Base URL `BASE/v1`, API Key: paste, Model `MODEL`. |
| Kilo Code | guided | OpenAI Chat | Kilo Code settings → API Provider: OpenAI Compatible → Base URL `BASE/v1`, API Key: paste, Model `MODEL`. |
| GitHub Copilot (VS Code BYOK) | guided | OpenAI Chat | VS Code → Copilot Chat → model picker → Manage Models… → OpenAI Compatible → URL `BASE/v1`/chat/completions, key: paste, model `MODEL`. (Copilot's Ollama option can't send an API key, so use OpenAI Compatible.) |
| Zed | guided | OpenAI Chat | Zed settings.json: "language_models": { "openai_compatible": { "Vortex": { "api_url": "`BASE/v1`", "available_models": [{ "name": "`MODEL`", "max_tokens": 32768 }] } } }. Then Agent panel → Configure → Vortex → paste the key. |
| JetBrains AI Assistant | guided | OpenAI Chat | Settings → Tools → AI Assistant → Models → Third-party AI providers → OpenAI-compatible: URL `BASE/v1`, API key: paste, model `MODEL`. (Its Ollama/LM Studio options send no key, so use OpenAI-compatible.) |

### Coding agents
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| Goose | guided | OpenAI Chat | Run goose configure → Configure Providers → OpenAI → OPENAI_HOST = `BASE`, OPENAI_BASE_PATH = v1/chat/completions, API key: paste, model `MODEL`. |

### Chat apps
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| Open WebUI | guided | OpenAI Chat | Admin Settings → Connections → OpenAI API → + : URL `BASE/v1`, key: paste. Models appear automatically. |
| LibreChat | guided | OpenAI Chat | librechat.yaml: endpoints: custom: - name: Vortex, apiKey: ${VORTEX_API_KEY}, baseURL: `BASE/v1`, models: { default: ["`MODEL`"], fetch: true }. Put the key in LibreChat's .env as VORTEX_API_KEY. |
| AnythingLLM | guided | OpenAI Chat | Settings → LLM Preference → Generic OpenAI: Base URL `BASE/v1`, API key: paste, Chat Model `MODEL`. |
| Msty | guided | OpenAI Chat | Add Remote Model Provider → OpenAI Compatible: endpoint `BASE/v1`, key: paste, add model `MODEL`. |
| Jan | guided | OpenAI Chat | Settings → Model Providers → Add provider: Base URL `BASE/v1`, API key: paste, then add model `MODEL`. |
| BoltAI | guided | OpenAI Chat | Settings → Models → + → OpenAI-compatible: API URL `BASE/v1`, key: paste, model `MODEL`. |
| Chatbox | guided | OpenAI Chat | Settings → Model Provider → Add → OpenAI API Compatible: API Host `BASE/v1`, key: paste, model `MODEL`. |
| Obsidian Copilot | guided | OpenAI Chat | Copilot settings → Model → Add Custom Model: provider 3rd party (openai-format), Base URL `BASE/v1`, key: paste, name `MODEL`. Turn on CORS if requests fail. |
| Apps built for LM Studio | guided | OpenAI Chat | LM Studio itself serves models and can't use a remote endpoint. Apps that talk to LM Studio's API (http://localhost:1234/v1) can point at `BASE/v1` with the key instead. |

### Automation
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| n8n | guided | OpenAI Chat | Credentials → OpenAI: API Key: paste, Base URL `BASE/v1`. Use the OpenAI Chat Model node with model `MODEL`. **Needs the public URL.** |
| Flowise | guided | OpenAI Chat | Use ChatOpenAI Custom (or ChatOpenAI → Additional Parameters → BasePath `BASE/v1`); credential = the key; model `MODEL`. **Needs the public URL.** |

### Chat apps
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| ChatGPT Custom GPT (Actions) | guided | OpenAPI | GPT editor → Configure → Actions → Import the schema (docs/openapi-gpt-actions.yaml, server = your public URL) → Authentication: API Key, Bearer → paste the key. **Needs the public URL.** |

### Not supported
| Tool | Mode | Protocol | Official mechanism / steps |
|---|---|---|---|
| Google Antigravity | not supported | — | Not supported by that app: the Antigravity IDE has no custom endpoint or bring-your-own-model setting (only its SDK does). |
| ChatGPT app | not supported | — | Not supported by that app: ChatGPT (desktop, web, mobile) only uses OpenAI's models. Use a Custom GPT with Actions instead. |
| Gemini app | not supported | — | Not supported by that app: the Gemini app has no custom model endpoint. Gemini CLI is supported. |
| Grok app | not supported | — | Not supported by that app: the official Grok app has no custom endpoint. The open-source Grok CLI is supported. |
| Claude.ai / Claude desktop | not supported | — | Not supported by that app: Claude.ai and the Claude desktop app only use Anthropic's models. Claude Code is supported. |


## Notes per tool
- **Codex CLI**: writes `~/.codex/vortex.config.toml` (Codex 0.163+ profile file) with `[model_providers.vortex]` (your default model is unchanged). The key goes in `~/.config/red-xai-vortex/env` (mode 600), which one marked line in `~/.zshrc` loads. Use `codex --profile vortex`.
- **Claude Code**: sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` in `~/.claude/settings.json`, so **all** Claude Code sessions use Vortex until you press Disconnect. Hosted Anthropic tools such as web search aren't available on local models.
- **Gemini CLI**: writes `~/.gemini/.env`. While it's connected, Gemini CLI uses the gateway instead of Google.
- **Aider / Continue / Raycast**: if you already have that config file, it's left alone. You get the key on your clipboard and add the snippet yourself.
- **Copilot / JetBrains**: their *Ollama* options can't send an API key, so use their OpenAI-compatible option.

## Not supported, and why
These apps have no official custom-endpoint setting. Changing them anyway would mean patching or proxying a paid service, so it isn't done:
- **ChatGPT app** (desktop/web/mobile): use a Custom GPT with Actions instead.
- **Gemini app**: use Gemini CLI.
- **Grok app**: use the open-source Grok CLI.
- **Claude.ai / Claude desktop**: use Claude Code.
- **Google Antigravity (IDE)**: no bring-your-own-endpoint (only the Antigravity SDK has `LocalOpenAIAgentConfig`).

## Test and Install
Each connected card has a **Test** button that sends a real prompt through that tool's config (or the same HTTP API the tool uses) and shows the reply on the card.
If a CLI tool is missing, an **Install** button runs the official installer (with confirmation).

Base URL for Mac tools is always `http://127.0.0.1:18091` (the app's SSH tunnel to the gateway public port). Nothing uses 18090.

## Verified end to end
- **Codex CLI 0.163** with `codex exec -p vortex` through the tunnel: provider `vortex` / Responses API auth works. Codex's default agent prompt is large — the llama.cpp server needs `n_ctx` ≥ ~16k (currently 8k on the VPS), or pick a model/server with a bigger window. A direct `/v1/responses` call with the same key returned `VORTEX_OK`.
- The Anthropic (`/v1/messages`, streaming, `x-api-key`), Responses and Gemini shims were tested with curl.
