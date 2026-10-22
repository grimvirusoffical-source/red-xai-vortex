# Server on Linux

Supported: Ubuntu 22.04/24.04 and Debian 12, x86_64 or arm64. A GPU is optional; CPU-only works well with AVX2.

## Install
```bash
git clone https://github.com/grimvirusoffical-source/red-xai-vortex && cd dolphino
sudo bash server/install.sh                      # portable crypto backend
# options: STARTER=qwen2.5-coder-7b  LLAMA_TAG=<llama.cpp tag>  CRYPTO_TAG=stdcrypto
```
The script:
1. builds llama.cpp (`llama-server` in router mode) into `/opt/dolphin/bin`
2. installs `dolphin-models`, the catalog and `dolphin-pool`
3. builds `dolphin-gateway` and runs it as a systemd service
4. creates `dolphin-llm.service` (127.0.0.1:8090) and `dolphin-gateway.service` (127.0.0.1:8091 public API, 127.0.0.1:8092 admin)
5. pulls a small starter model and writes an admin key to `/root/dolphino-admin.key` (mode 600)

Everything binds to localhost. Keep the firewall at SSH-only and use an SSH tunnel or a
tunnel/reverse proxy (see PUBLIC-ACCESS.md).

## Manage models
```bash
dolphin-models available           # catalog with size, RAM need, speed
dolphin-models pull qwen2.5-coder-14b
dolphin-models list
dolphin-models default qwen2.5-coder-14b
dolphin-models remove qwen2.5-coder-14b   # deletes the file and frees the disk
```
Limits: 200 GB total for models, 20 GB disk kept free, and RAM need must be ≤ 27 GB (edit the top of the script to change these).

## Sizing guide (CPU, Q4)
| RAM | Comfortable models |
|---|---|
| 8 GB | 1–4B (Llama 3.2 3B, Phi-4 mini) |
| 16 GB | up to 8–14B |
| 32 GB | up to 32B, Mixtral 8x7B |

## Logs
`journalctl -u dolphin-llm -f` · `journalctl -u dolphin-gateway -f`

## Owner bans

```bash
vortex-ban list    # banned IPs / device ids / attempt counters
vortex-ban clear   # wipe bans (SSH only)
```

See [OWNER.md](OWNER.md).
