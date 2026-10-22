# Owner vs user permissions

| Action | Owner (admin key, over SSH tunnel) | App / user key `redx_ai_…` | Vortex key `redx_xai_…` |
|---|---|---|---|
| Chat / completions with allowed models | ✅ all | ✅ allowed models | ✅ with `chat` scope |
| Embeddings | ✅ | ✅ | ✅ `embeddings` scope |
| Images / audio | ✅ | ❌ | ✅ `image` / `audio` scope |
| Teach Vortex (ingest, feedback) | ✅ | ❌ | ✅ `train:submit` |
| Download / remove models **on the VPS** | ✅ | ❌ | ❌ |
| Download models **to their own computer** (Local mode) | ✅ | ✅ (their machine) | ✅ (their machine) |
| Create / revoke keys, merges, providers | ✅ | ❌ | ❌ |
| Turn learning on, run training, change storage | ✅ | ❌ | ❌ |
| See provider secrets or storage secrets | ❌ (sealed, never returned) | ❌ | ❌ |

How it's enforced:
- The **admin API only listens on 127.0.0.1:8092** on the server, so it can only be reached through SSH, and it only accepts the admin key. The public port (8091) gives the admin key a 404.
- Keys are stored as HMAC fingerprints, and the plaintext is shown once.
- Each key can be limited to models and requests per minute, and revoked instantly.
- Training data is only collected with training mode **and** consent on, PII is scrubbed twice (app and server), and it's sealed at rest.
