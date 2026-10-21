# Outside providers

Add any OpenAI-compatible API. Its key is sealed on the server with an AEAD under a server-only key,
and no endpoint ever returns it.

| Provider | Base URL |
|---|---|
| OpenAI | `https://api.openai.com/v1` |
| Anthropic (OpenAI SDK compatibility) | `https://api.anthropic.com/v1` |
| Groq | `https://api.groq.com/openai/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Together | `https://api.together.xyz/v1` |
| Mistral | `https://api.mistral.ai/v1` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` |

Each model you add gets an id like `ext-<provider>-<your-name>` and your display name. It shows up in `/v1/models`, follows the per-key allowed-model rules, and can be used in merges.

```bash
curl 127.0.0.1:8092/admin/providers -H "Authorization: Bearer $ADMIN" -d '{
  "name":"Groq","base_url":"https://api.groq.com/openai/v1","api_key":"…",
  "models":[{"remote":"llama-3.3-70b-versatile","name":"Groq Llama 70B"}]}'
curl -X POST 127.0.0.1:8092/admin/providers/groq/test -H "Authorization: Bearer $ADMIN"
```
Only `https://` base URLs are accepted, apart from `http://localhost`.
