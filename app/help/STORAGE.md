# Overflow storage for training data

When disk use on `/` reaches **80%** (`offload_pct` in the Vortex config), the gateway moves training data off the server:

1. Candidates: closed dataset files (`datasets/*.rxds` other than the current month) and exports (`export/*.jsonl`). The knowledge store stays local because Vortex needs it to answer.
2. Each file is **sealed** with the gateway's AEAD (the production build links rsx) under a key that never leaves the server, then uploaded as `<name>.<timestamp>.vxo`.
3. The object is read back and compared byte for byte; only then is the local file deleted.
4. An index (`/opt/dolphin/redxai/offloaded.json`) records what went where; **Restore** brings a file back and unseals it.

The check runs every 10 minutes. You can also press **Offload now** in the Vortex tab.

## Backends
| Kind | Works with | Settings |
|---|---|---|
| `s3` | Vultr Object Storage, Cloudflare R2, Backblaze B2, Wasabi, MinIO, AWS S3 | endpoint (`https://ewr1.vultrobjects.com`), bucket, region (`us-east-1` if unsure), access key, secret |
| `webdav` | Nextcloud, ownCloud, Synology, Koofr, pCloud (WebDAV), any HTTPS WebDAV | folder URL (https only), username, password/app password |
| `terabox` | TeraBox | **not enabled**, see below |

Secrets are sealed on the server like provider keys and never returned by the API.
The S3 signer (SigV4) uses the linked crypto backend's SHA-256 and HMAC.

```bash
# admin API (over the SSH tunnel)
curl -H "Authorization: Bearer $ADMIN" localhost:18092/admin/storage -d '{"kind":"s3","endpoint":"https://ewr1.vultrobjects.com","bucket":"vortex","access_key":"…","secret":"…","prefix":"vortex-train"}'
curl -XPOST -H "Authorization: Bearer $ADMIN" localhost:18092/admin/storage/test -d '{}'
curl -XPOST -H "Authorization: Bearer $ADMIN" localhost:18092/admin/storage/offload -d '{"force":true}'
curl -XPOST -H "Authorization: Bearer $ADMIN" localhost:18092/admin/storage/restore -d '{"remote":"datasets_feedback-202609.rxds.20261022.vxo"}'
```

## TeraBox
TeraBox has an official **Open Platform** (precreate → upload shards → create). It's built for registered partner apps:
- you need an approved developer application (app id/key) and a user OAuth access token;
- uploads go into a fixed app folder and need an MD5 list of 4 MB+ shards;
- the free 1 TB account itself has to be created by you.

Third-party tools that use TeraBox's private web API (cookies, `jsToken`) break often and are against its terms, so they aren't used here.
Until an Open Platform app is approved, use an S3-compatible bucket (Vultr Object Storage is in the same data centres as the server) or a WebDAV drive. The `StorageBackend` interface (`Put`/`Get`/`Delete`) is where a TeraBox backend will slot in.
