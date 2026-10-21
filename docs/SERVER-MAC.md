# Server on macOS

The installer targets Linux (systemd). On a Mac you can run the same pieces by hand:
```bash
brew install llama.cpp go python
mkdir -p ~/dolphin/models && sudo mkdir -p /etc/dolphin/gateway /opt/dolphin && sudo chown -R $USER /etc/dolphin /opt/dolphin
ln -s ~/dolphin/models /opt/dolphin/models
cp server/catalog.json /etc/dolphin/ && cp server/dolphin-models /usr/local/bin/
openssl rand -hex 32 > /etc/dolphin/api-keys
llama-server --host 127.0.0.1 --port 8090 --models-dir /opt/dolphin/models --models-max 1 --api-key-file /etc/dolphin/api-keys --jinja &
cd gateway && go build -tags stdcrypto -o dolphin-gateway . && ./dolphin-gateway init-admin ~/dolphino-admin.key && ./dolphin-gateway
```
On macOS, `dolphin-models pull` tries to restart a systemd unit; restart `llama-server` yourself after pulling.
Built-in **Local mode** in the Dolphino app (Metal, on demand) is in progress.
