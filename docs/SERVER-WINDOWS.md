# Server on Windows

The server runs on Linux. On Windows use **WSL2** with systemd:

1. PowerShell (admin): `wsl --install -d Ubuntu-24.04`, then reboot.
2. In Ubuntu, enable systemd by putting this in `/etc/wsl.conf`:
   ```
   [boot]
   systemd=true
   ```
   Then run `wsl --shutdown` from PowerShell and reopen Ubuntu.
3. `git clone https://github.com/grimvirusoffical-source/red-xai-vortex && cd dolphino && sudo bash server/install.sh`
4. WSL forwards `localhost`, so Windows apps can use `http://127.0.0.1:8091/v1` (OpenAI) or `http://127.0.0.1:8091` (Ollama) with a `redx_ai_` key.

NVIDIA GPUs: install the CUDA WSL driver, then rebuild llama.cpp with `-DGGML_CUDA=ON` (see llama.cpp docs) and copy the binaries to `/opt/dolphin/bin`.

**Windows client app:** planned. Until then use any OpenAI- or Ollama-compatible client (Open WebUI, Continue, Cline, LibreChat…).
