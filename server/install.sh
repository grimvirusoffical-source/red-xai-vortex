#!/usr/bin/env bash
# Red-XAI Vortex server installer: llama.cpp (router mode) + dolphin-gateway + dolphin-models.
# Tested on Ubuntu 22.04/24.04 and Debian 12 (x86_64 / arm64). Run as root:
#   curl -fsSL https://raw.githubusercontent.com/grimvirusoffical-source/red-xai-vortex/main/server/install.sh | bash
# or from a checkout:  sudo bash server/install.sh
# Options (env): LLAMA_TAG=<tag>  CRYPTO_TAG=stdcrypto|rsx  STARTER=llama3.2-3b  WITH_MEDIA=1 (image+audio, ~15 GB)
# Existing install: check only (never rebuild/downgrade the gateway or rotate the admin key).
if [ "${DOLPHINO_REINSTALL:-0}" != 1 ] && [ -x /usr/local/bin/dolphin-gateway ] && systemctl is-active --quiet dolphin-gateway; then
  echo "Existing Red-XAI server detected: running checks only (set DOLPHINO_REINSTALL=1 to reinstall)."
  for s in dolphin-gateway dolphin-llm cloudpc-web; do printf "  %-16s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null)"; done
  printf "  %-16s %s\n" "public :8091" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8091/healthz)"
  printf "  %-16s %s\n" "admin key" "$([ -s /root/dolphino-admin.key ] && echo present || echo MISSING)"
  printf "  %-16s %s free\n" "disk /" "$(df -h / | awk 'NR==2{print $4}')"
  exit 0
fi
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/grimvirusoffical-source/red-xai-vortex/main}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd || echo)"
CRYPTO_TAG="${CRYPTO_TAG:-stdcrypto}"
STARTER="${STARTER:-llama3.2-3b}"
log(){ echo -e "\033[1;34m==>\033[0m $*"; }

log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates git build-essential cmake python3 libcurl4-openssl-dev golang-go >/dev/null

id dolphin >/dev/null 2>&1 || useradd --system --home /opt/dolphin --shell /usr/sbin/nologin dolphin
mkdir -p /opt/dolphin/{bin,models,cache,datasets} /etc/dolphin/gateway
chmod 700 /etc/dolphin/gateway

if [ ! -x /opt/dolphin/bin/llama-server ]; then
  log "Building llama.cpp (CPU, native); this takes a few minutes"
  rm -rf /opt/dolphin/src && git clone -q --depth 1 ${LLAMA_TAG:+--branch $LLAMA_TAG} https://github.com/ggml-org/llama.cpp /opt/dolphin/src
  cmake -S /opt/dolphin/src -B /opt/dolphin/src/build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DGGML_RPC=ON -DLLAMA_CURL=ON >/dev/null
  cmake --build /opt/dolphin/src/build -j"$(nproc)" --target llama-server llama-bench rpc-server >/dev/null
  cp /opt/dolphin/src/build/bin/llama-server /opt/dolphin/src/build/bin/llama-bench /opt/dolphin/bin/
  cp /opt/dolphin/src/build/bin/rpc-server /opt/dolphin/bin/ggml-rpc-server 2>/dev/null || true
  find /opt/dolphin/src/build -name '*.so*' -exec cp -P {} /opt/dolphin/bin/ \; 2>/dev/null || true
fi

fetch(){ # fetch <repo-path> <dest>
  if [ -n "$SRC" ] && [ -f "$SRC/$1" ]; then cp "$SRC/$1" "$2"; else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi; }

log "Installing model manager and catalog"
fetch server/dolphin-models /usr/local/bin/dolphin-models; chmod 755 /usr/local/bin/dolphin-models
fetch server/catalog.json /etc/dolphin/catalog.json
fetch server/dolphin-pool /usr/local/bin/dolphin-pool; chmod 755 /usr/local/bin/dolphin-pool
for f in redxai-crawl redxai-eval redxai-train vortex-preload; do fetch server/$f /usr/local/bin/$f; chmod 755 /usr/local/bin/$f; done
mkdir -p /opt/dolphin/redxai /etc/dolphin/redxai /opt/dolphin/audio; fetch server/audio/gen.py /opt/dolphin/audio/gen.py; fetch server/audio/gen2.py /opt/dolphin/audio/gen2.py
fetch server/media-setup.sh /opt/dolphin/media-setup.sh
[ "${WITH_MEDIA:-0}" = 1 ] && { log "Installing image + audio generation (large, slow)"; bash /opt/dolphin/media-setup.sh >/opt/dolphin/cache/media-setup.log 2>&1 || true; }

log "Building gateway (crypto backend: $CRYPTO_TAG)"
GW=/opt/dolphin/src-gateway; rm -rf $GW; mkdir -p $GW
for f in go.mod access.go agents_bg.go crypto_std.go crypto_stub.go distill_job.go jobs.go learn.go link_off.go main.go media.go nodes.go ollama.go owner.go providers.go redxai.go shim.go shim_gemini.go storage.go sysstats.go; do fetch gateway/$f $GW/$f; done
[ "$CRYPTO_TAG" = rsx ] && [ ! -f $GW/crypto_rsx.go ] && { echo "rsx build needs the private crypto_rsx.go + SDK; falling back to stdcrypto"; CRYPTO_TAG=stdcrypto; } || true
(cd $GW && CGO_ENABLED=0 go build -tags "$CRYPTO_TAG" -trimpath -ldflags="-s -w" -o /usr/local/bin/dolphin-gateway .)

log "Generating internal model-server key"
[ -s /etc/dolphin/api-keys ] || (head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo) > /etc/dolphin/api-keys
chown root:dolphin /etc/dolphin /etc/dolphin/api-keys; chmod 750 /etc/dolphin; chmod 640 /etc/dolphin/api-keys
[ -f /etc/dolphin/pool.env ] || echo "DOLPHIN_POOL_ARGS=" > /etc/dolphin/pool.env
[ -f /etc/dolphin/presets.ini ] || printf 'version = 1\n' > /etc/dolphin/presets.ini

log "Installing services"
fetch server/dolphin-llm.service /etc/systemd/system/dolphin-llm.service
fetch server/dolphin-gateway.service /etc/systemd/system/dolphin-gateway.service
THREADS=$(nproc); MEM=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 - 3 ))
sed -i "s/-t 16/-t $THREADS/; s/MemoryMax=29G/MemoryMax=${MEM}G/" /etc/systemd/system/dolphin-llm.service
chown -R dolphin:root /opt/dolphin
systemctl daemon-reload
systemctl enable --now dolphin-llm dolphin-gateway
# SSH-only owner ban recovery
cat > /usr/local/bin/vortex-ban <<'"'"'B'"'"'
#!/bin/sh
exec /usr/local/bin/dolphin-gateway vortex-ban "$@"
B
chmod 0755 /usr/local/bin/vortex-ban

if [ -n "$STARTER" ] && [ -z "$(ls /opt/dolphin/models 2>/dev/null)" ]; then
  log "Downloading starter model $STARTER"; dolphin-models pull "$STARTER" || true
  dolphin-models default "$STARTER" || true
fi

if [ ! -s /root/dolphino-admin.key ]; then dolphin-gateway init-admin /root/dolphino-admin.key; systemctl restart dolphin-gateway; fi
log "Done."
echo "  Model server : 127.0.0.1:8090 (private)"
echo "  Gateway      : 127.0.0.1:8091 (OpenAI + Ollama API, needs a redx_ai_ key)"
echo "  Admin API    : 127.0.0.1:8092 (admin key in /root/dolphino-admin.key, chmod 600)"
echo "  Nothing is exposed publicly. Reach it over SSH or put a tunnel/reverse proxy in front of :8091."
