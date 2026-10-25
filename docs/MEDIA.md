# Media (image, speech, music, sound effects, video)

Open **Media**, choose a type, enter a prompt and **Queue**. Jobs run one at a time on the server with a
live progress bar (load → generate → decode) and appear in the list when done.

| Type | Engine | Typical time (32 vCPU) |
|---|---|---|
| Image 512² | stable-diffusion.cpp (SD-Turbo) | ~15–20 s |
| Speech | TTS | a few seconds |
| Music / SFX | MusicGen-small | ~15–20 s per 5 s clip |
| Short video | frame generation + assembly | minutes |
