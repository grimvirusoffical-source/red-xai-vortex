# Red-XAI: a learning model built on open models

Red-XAI isn't trained from scratch. It's an honest stack:

| Layer | What it does | Runs on |
|---|---|---|
| **Core** | Model `red-xai`: the best local base (default Dolphin Mixtral 8x7B) plus the Red-XAI persona | CPU ✅ |
| **Capability routing** | code goes to the coder (Qwen2.5-Coder), long logic and math go to the reasoner (R1-Distill), everything else to the base | CPU ✅ |
| **Memory (RAG)** | Each message is embedded (`nomic-embed-v1.5`) and the closest chunks from the knowledge store are injected, so it learns facts **immediately** | CPU ✅ |
| **Training mode** | Opt-in in Dolphino (off by default, plus a consent switch). 👍/👎 and corrections go to a sealed, PII-scrubbed dataset | ✅ |
| **Crawler** | Admin seed URLs, robots.txt, per-host delay, page cap, allow/deny regexes, URL and content dedupe, into the knowledge store | ✅ |
| **Real learning** | LoRA fine-tunes on the dataset produce versions `red-xai-v1`, `v2`, … with a built-in benchmark | needs a GPU to be practical |
| **Image** | stable-diffusion.cpp + SD-Turbo, 512×512, 1–4 steps | CPU: slow (see below) |
| **Music/sound** | MusicGen-small | CPU: slow |

## Storage
- Knowledge: `/opt/dolphin/redxai/kb/kb-*.rxkb`, sealed AEAD shards (text + vectors), with keys in `/etc/dolphin/gateway/` (mode 600).
- Dataset: `/opt/dolphin/redxai/datasets/feedback-YYYYMM.rxds`, one sealed record per line.
- `export` writes a plaintext JSONL (mode 600) only when you ask for one, for the trainer.

## Teaching it
```bash
# from any app with a redx_xai_ key that has train:submit
curl https://YOUR_DOMAIN/v1/redxai/ingest -H "Authorization: Bearer $KEY" \
  -d '{"documents":[{"source":"docs:faq","text":"…"}]}'
curl https://YOUR_DOMAIN/v1/redxai/feedback -H "Authorization: Bearer $KEY" \
  -d '{"consent":true,"rating":-1,"messages":[{"role":"user","content":"…"}],"response":"…","correction":"…"}'
```
Forget a source: `DELETE /admin/redxai/kb?source=https://site/*`.

## Crawler
`/etc/dolphin/redxai/crawl.json` (or the Red-XAI tab):
```json
{"seeds":["https://docs.example.com/"],"max_pages":200,"delay_seconds":2,"same_domain":true,"allow":[],"deny":["/login"]}
```
Run `redxai-crawl` (or click Crawl now). Sites that block crawlers in robots.txt are skipped, and so are sites that answer robots.txt with a login redirect.

## Training versions (LoRA)
```bash
redxai-train export      # -> /opt/dolphin/redxai/export/train-*.jsonl (thumbs-up replies + corrections)
redxai-train gpu-help    # rented-GPU recipe (Unsloth/Axolotl -> convert_lora_to_gguf.py)
redxai-train install red-xai-lora.gguf   # becomes v1, v2, …; router loads base + adapter as red-xai-vN
redxai-train activate v2 # what "red-xai" uses
redxai-eval              # benchmark every version; results in the app's Red-XAI tab
```
CPU-only training: practical only for tiny adapters on 1–3B models, and hours per epoch. Train on a rented GPU (an hour or two on a 24–48 GB card is enough for thousands of examples) and serve on the CPU.
The adapter must be trained on the same base as `base` in `/etc/dolphin/redxai/config.json`.

## Media on CPU (16 vCPU reference)
Install with `WITH_MEDIA=1 bash server/install.sh` or `bash /opt/dolphin/media-setup.sh`.
- Image, SD-Turbo 512×512 at 1–4 steps: about 15–60 s per image. Larger sizes and SDXL-Turbo are much slower.
- Music, MusicGen-small: several times slower than real time (8 s of audio takes minutes).
- Licenses: **SD-Turbo** (Stability AI Non-Commercial Research Community License) and **MusicGen** weights (CC-BY-NC 4.0) are **non-commercial**. For commercial use, swap in an openly licensed model (for example SD 1.5 under CreativeML OpenRAIL-M) under `/opt/dolphin/media-models/image/`.
- While generating media, loaded chat models are unloaded to free RAM.
