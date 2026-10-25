# Models and the library

Open **Library** (macOS: ⌘⇧L → Library) to download, remove and set the default model.

- Each entry shows size, RAM needed and expected speed. Disk and RAM are checked before each download.
- The server uses the whole data disk for models (reserve of 50 GB for the system); there is no fixed 200 GB cap.
- Up to three models stay loaded at once; the least recently used one is unloaded when a new one is needed.
- Vision: **Qwen2.5-VL-7B** reads images you attach.
- Recommended on a 32 vCPU / 64 GB CPU server: Vortex 8B (fast general), Qwen2.5-Coder-14B (code),
  R1-Distill-Qwen-14B (reasoning), Vortex 24B or a 32B Q4 model (quality; at most two 32B resident),
  Qwen2.5-VL-7B (vision), nomic-embed (memory). Models above ~40 GB (e.g. 72B, or 236B MoE models like
  DeepSeek-V2.5) don't fit in RAM on this class of server.
- Browse more in the Model Browser — see [MODEL-BROWSER.md](MODEL-BROWSER.md).
