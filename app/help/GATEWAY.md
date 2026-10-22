# Gateway build & crypto backends

The gateway needs a CSPRNG, HMAC-SHA256 (key hashing) and a 256-bit AEAD (provider-key sealing). They sit behind four functions (`cbRandom`, `cbHMAC`, `cbSeal`, `cbOpen`) and are chosen with a build tag:

| Tag | Backend |
|---|---|
| `stdcrypto` | Go standard library (AES-256-GCM). Use this for normal installs |
| `rsx` | Red-SecretsXAI SDK (private, not included). Needs `go mod edit -require redsecretsxai@v0.0.0 -replace redsecretsxai=/path/to/sdk/go` |
| *(none)* | stub that refuses to run |

```bash
cd gateway && CGO_ENABLED=0 go build -tags stdcrypto -trimpath -o dolphin-gateway .
./dolphin-gateway init-admin /root/dolphino-admin.key   # creates/rotates the admin key
```
State lives in `/etc/dolphin/gateway/` (mode 700): `keys.json` (hashes only), `merges.json`, `providers.json` (sealed keys), `pepper` and `seal.key`.
