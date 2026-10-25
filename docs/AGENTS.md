# Agents

## Agents (in-app)
Create an agent with a name, a model (any Vortex model **or** an external AI with your own API key:
OpenAI, Anthropic, Google, xAI, OpenRouter, Ollama, any OpenAI-compatible URL), instructions and tools
(PC control with Allow/Deny, web, files, plugins, skills). Keys stay in the OS keychain.

## Background agents (run until you turn them off)
macOS: **Agents → Background agents**. API: `/v1/agents`.

- Give it a **standing goal**, optional instructions, a model and an interval (1 min – 24 h).
- **Run on**: *Vortex server* (always on, keeps going when your computer is off or the app is closed)
  or *Cloud PC* (only for accounts with approved Cloud PC access).
- Toggle **Running** on/off at any time. An agent stops by itself if it replies `DONE`.
- **Chat** with any agent: each agent keeps its own history (up to 400 turns); background runs are shown dimmed.
- New replies raise a notification and an unread badge. Optional: **Keep running at login** adds a login item
  so the app checks in after restart.

API (with your `redx_ai_…` key):
```
GET    /v1/agents                 list
POST   /v1/agents                 create/update {name, model, goal, system, interval_s, run_on, on}
GET    /v1/agents/{id}            details + history (clears unread)
POST   /v1/agents/{id}/toggle     {"on": true|false}
POST   /v1/agents/{id}/chat       {"content": "..."}
DELETE /v1/agents/{id}
```
