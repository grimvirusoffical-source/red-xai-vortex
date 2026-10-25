# Exposing the gateway publicly

Only expose port **8091** (the keyed API), never 8090 (the model server) or 8092 (admin).

## Cloudflare Tunnel (no open ports)
```bash
cloudflared tunnel login
cloudflared tunnel create vortex
cloudflared tunnel route dns vortex ai.YOUR_DOMAIN
cat > /etc/cloudflared/config.yml <<CFG
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: ai.YOUR_DOMAIN
    service: http://127.0.0.1:8091
  - service: http_status:404
CFG
cloudflared service install && systemctl enable --now cloudflared
```
The API token needs **Account › Cloudflare Tunnel: Edit** and **Zone › DNS: Edit**.

## Reverse proxy (Caddy)
```
ai.YOUR_DOMAIN {
  reverse_proxy 127.0.0.1:8091 { flush_interval -1 }
}
```
