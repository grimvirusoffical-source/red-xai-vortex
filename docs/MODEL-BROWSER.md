# Model browser (local web page)

Click **Browse Models** (the safari icon in the chat toolbar, Library tab, or ⇧⌘B). Red-XAI Vortex starts a
server on `127.0.0.1` with a random port and opens `http://127.0.0.1:<port>/?t=<token>` in your default browser.

- **Curated**: the catalog by category, showing size, RAM need, speed and license.
- **Ollama library**: about 250 families from ollama.com/library with search, capability badges, size buttons and **All tags…** for every quantization. Downloads come straight from the Ollama registry as GGUF and run on llama.cpp.
- **Installed**: Remove (frees disk) and **Add to merge** (as a member or judge).
- **Install on**: any configured server, or **This Mac** (local Metal mode). Progress bars update live.

Security: binds to 127.0.0.1 only. It checks the Host header (no DNS rebinding), requires the per-session token
on every request (an `X-Token` header for changes), and sends `no-store`, `X-Frame-Options: DENY` and `no-referrer`.
The token changes every time Red-XAI Vortex starts. The page talks to the gateway admin API through Red-XAI Vortex's SSH tunnels.
