# Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| App says "not connected" / tunnel error | SSH host or key wrong, server down | Settings → Connection: check `root@YOUR_SERVER`, then **Test Connection**. On the server: `systemctl status dolphin-gateway dolphin-llm` |
| macOS asks for Keychain access | New app version or a renamed app | Click **Always Allow** (the admin key lives in the Keychain) |
| 401 invalid or missing API key | Wrong or revoked key, missing `Bearer ` | Create a new key; send `Authorization: Bearer redx_…` |
| 403 this key may not use model | The key is limited to other models | Edit the key's models or use an allowed model |
| 404 model not installed | Typo, or the model was removed | `GET /v1/models` for exact ids |
| 429 rate limit | Too many requests per minute | Raise the key's requests per minute |
| 502 model server unavailable | The model service is restarting (after a download or install) or ran out of RAM | Wait 10–30 s; `journalctl -u dolphin-llm -n 50` |
| First reply is very slow | The model is loading from disk into RAM | Normal; later replies are faster. Max 2 models stay loaded |
| Reasoning model returns an empty answer | Too few tokens to finish thinking | Use `max_tokens` ≥ 2048 (merges do this automatically) |
| Download fails "not enough disk/RAM" | Pre-checks | Uninstall unused models, or pick a smaller quantization |
| Merge is slow | Steps run one after another | Use Router, or smaller drafters (see MERGES.md) |
| Image/audio 503 "not installed" | Media add-on not set up | `bash /opt/dolphin/media-setup.sh` |
| Vortex doesn't know something you taught it | Text too short, or a low match score | Add longer, specific text; check **Knowledge chunks** went up |
| Crawler added nothing | robots.txt blocks it, or the site needs a login | Use another source, or paste the text |
| Storage **Test** fails | Wrong endpoint, region, bucket or secret; WebDAV must be https | Check the values; for S3 try region `us-east-1` |
| Model browser says Forbidden | Opened without the session token | Open it from the app's **Browse Models** button |
| Ollama app can't connect | It can't send an Authorization header | Use the app's OpenAI mode instead |
| Custom GPT action fails | Using the SSH tunnel URL | Actions need the public https URL |

Useful server commands:
```bash
systemctl status dolphin-gateway dolphin-llm
journalctl -u dolphin-gateway -n 50 --no-pager
dolphin-models list           # installed models
df -h /                       # disk
dolphin-pool status
vortex-preload list
```
