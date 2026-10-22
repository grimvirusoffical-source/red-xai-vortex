# Servers, failover, pooling and nodes

## Words used here
- **Server**: a machine that runs the gateway and models (a VPS or a home machine).
- **Node / worker**: a machine that *lends* its CPU/GPU to a server through llama.cpp's **RPC** worker (`ggml-rpc-server` / `rpc-server`). It doesn't run the gateway.
- **Pool**: a server plus its nodes, used together to run one model.

## Several servers + failover (app: Library, Merges & Keys → Servers)
1. **Add a server**: name, `root@YOUR_SERVER`, SSH key login.
2. **Install / Update**: runs `server/install.sh` over SSH (llama.cpp router, gateway, model manager, systemd services).
3. Paste or create the server's admin key. It's stored in the macOS Keychain.
4. **Per-model target**: in the Library choose which server holds which model.
5. **Fail over automatically** (on by default): if the active server stops answering, the app tries the next server, then this Mac (Local mode), and shows which one it's using.

## Pooling with this Mac (app: Settings → Compute)
- **Share this Mac's CPU/GPU** starts a Metal RPC worker bound to `127.0.0.1` and an SSH *reverse* tunnel, so only the server can reach it.
- On the server: `dolphin-pool on` adds `--rpc 127.0.0.1:50052` and restarts the model service. `dolphin-pool off` removes it, and `dolphin-pool status` shows the state.
- It's off by default, and turns off when the app quits.

## Pooling with a second server (e.g. a node in another region)
For example, a second VPS in another city (such as an Atlanta region) added as a worker:
1. On the node: build llama.cpp with `-DGGML_RPC=ON` and run `rpc-server -H 127.0.0.1 -p 50052` as a service. **Never bind it to a public IP**: RPC has no authentication.
2. Connect the two privately: an SSH tunnel from the main server (`ssh -N -L 50053:127.0.0.1:50052 root@NODE_IP`), WireGuard, or the provider's private network (VPC).
3. On the main server, add the tunnel's port to the pool (`--rpc 127.0.0.1:50052,127.0.0.1:50053`) and restart `dolphin-llm`.
4. Check that `systemctl status dolphin-llm` shows the RPC devices, and that `/v1/models` still answers.

What to expect:
- Pooling lets a model **bigger than one machine's RAM** load across machines.
- Over the internet it's **slower** per token than one machine, because every token waits for the network. Use servers in the same region or data centre when you can.
- If a node drops, models using it fail until you run `dolphin-pool off` (or remove that node) and restart.
- Node ≠ failover: a node helps one server; failover switches between whole servers.
