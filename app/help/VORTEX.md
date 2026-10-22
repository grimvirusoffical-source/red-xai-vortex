# Vortex: the Red-XAI learning model, built on open models

**Vortex** is the AI inside Red-XAI Vortex. Call it as model `vortex` (or the older alias `red-xai`; versions are `vortex-v1`, `vortex-v2`, …).
It isn't trained from scratch. It's an honest stack:

| Layer | What it does | Runs on |
|---|---|---|
| **Core** | Model `vortex`: the best local base (default Dolphin Mixtral 8x7B) plus the Vortex persona | CPU ✅ |
| **Capability routing** | code goes to the coder (Qwen2.5-Coder), long logic and math go to the reasoner (R1-Distill), everything else to the base | CPU ✅ |
| **Memory (RAG)** | Each message is embedded (`nomic-embed-v1.5`) and the closest chunks from the knowledge store are injected, so it learns facts **immediately** | CPU ✅ |
| **Training mode** | Opt-in in Red-XAI Vortex (off by default, plus a consent switch). 👍/👎 and corrections go to a sealed, PII-scrubbed dataset | ✅ |
| **Crawler** | Admin seed URLs, robots.txt, per-host delay, page cap, allow/deny regexes, URL and content dedupe, into the knowledge store | ✅ |
| **Learns from the active model** | With learning ON (owner) and Training mode + consent ON (app), replies from whatever model or merge you chat with are captured, scrubbed, sealed, judge-scored; only the best are distilled into Vortex | ✅ capture/score · training needs a GPU |
| **Preloaded knowledge** | Open datasets (Dolly, OpenAssistant, Python docs, Simple Wikipedia) via `vortex-preload` | ✅ |
| **Real learning** | LoRA fine-tunes on the dataset produce versions `red-xai-v1`, `v2`, … with a built-in benchmark | needs a GPU to be practical |
| **Image** | stable-diffusion.cpp + SD-Turbo, 512×512, 1–4 steps | CPU: slow (see below) |
| **Music/sound** | MusicGen-small | CPU: slow |
| **PC control** | Tools on your own Mac, opt-in per type | ✅ build 20 (see [PC-CONTROL.md](PC-CONTROL.md)) |

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
- Image, SD-Turbo 512×512 at 4 steps: **15 s** measured on the 16 vCPU reference. Larger sizes and SDXL-Turbo are much slower.
- Music, MusicGen-small: **5 s of audio in 18 s** measured (first call also downloads the weights).
- Licenses: **SD-Turbo** (Stability AI Non-Commercial Research Community License) and **MusicGen** weights (CC-BY-NC 4.0) are **non-commercial**. For commercial use, swap in an openly licensed model (for example SD 1.5 under CreativeML OpenRAIL-M) under `/opt/dolphin/media-models/image/`.
- While generating media, loaded chat models are unloaded to free RAM.

## Learning from the active model (distillation)
1. Owner turns on **Vortex → Learn from the active model** (`POST /admin/redxai/config {"learn":true}`).
2. In the app, turn on **Training mode** and **consent**. The app then sends `X-Vortex-Train: 1` with each chat; any other client can send the same header with a key.
3. The gateway captures the conversation and the final reply of the model that answered (plain model, outside provider or merge), scrubs PII and appends it sealed to the dataset (`kind: distill`, `teacher: <model>`).
4. **Score now** (or `POST /admin/redxai/distill/score`) asks the judge (Vortex's base) to rate each capture 1–10. Scores are stored by record id only.
5. `redxai-train export` includes captures scoring ≥ `learn_min_score` (default 8) plus your 👍 and corrections. Train a LoRA on a GPU, `redxai-train install`, and Vortex gets the teacher's best behaviour as `vortex-vN`.
Status: `GET /admin/redxai/distill`.

## Preloaded knowledge (open datasets)
```bash
vortex-preload list
vortex-preload dolly          # databricks-dolly-15k, CC BY-SA 3.0
vortex-preload oasst          # OpenAssistant top-1 conversations, Apache-2.0
vortex-preload pydocs         # Python 3.14 library docs, PSF-2.0
vortex-preload wiki 15000     # Simple English Wikipedia (first N articles), CC BY-SA 4.0 / GFDL
```
Everything is tagged `dataset:<name>/…`; remove a set with `DELETE /admin/redxai/kb?source=dataset:wiki*`. The loader stops above 75% disk.
Rough cost: about 3 KB RAM and 8 KB disk per chunk; the default set is roughly 60–80k chunks (≈250 MB RAM, ≈600 MB disk) and takes a few hours to embed on CPU.
Attribution: CC BY-SA content stays under CC BY-SA when you redistribute it.

## Overflow storage
See [STORAGE.md](STORAGE.md). At 80% disk use, closed training files are sealed and moved to S3-compatible storage or WebDAV.

## Who can download models where
- **VPS downloads** go through the admin API, which only the owner's admin key can reach (over SSH). App keys (`redx_ai_`, `redx_xai_`) can never pull models onto the server.
- **Everyone else** downloads to their own machine with Local mode.
- The owner picks **This Mac** or a **server** as the target in the Library and the model browser.
