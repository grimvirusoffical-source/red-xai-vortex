# Owner Panel

The **Owner** tab in Library, Merges & Keys is for the server owner only.

## Unlock
1. Open **Owner**.
2. Enter the owner password. The app sends it to the gateway over the SSH tunnel; the gateway checks an **rsx Argon2id** hash (`/etc/dolphin/gateway/owner.phc`). The password itself is never stored on the Mac.
3. After unlock (12 hours on that device) you can use VPS downloads, servers/nodes, learning, keys, storage and the ban list. Those admin actions return `owner unlock required` until then.

## Lockout
Failed unlocks are counted **on the server** by device id (SHA-256 of the Mac hardware UUID). Reinstalling the app does **not** reset the counter.

After **3** wrong passwords from one device:
- the server bans that **device id** and the device's **public IP**
- the app deletes `/Applications/Red-XAI Vortex.app`, its Keychain items and Application Support data, then quits
- the public API and model browser refuse that IP / device (`403 device or IP banned`), so a reinstall cannot reconnect or pull models

## SSH recovery
On the VPS (SSH only):

```bash
vortex-ban list    # show banned IPs, devices, attempt counts
vortex-ban clear   # wipe the ban list and attempt counters
```

`vortex-ban` is a wrapper around `dolphin-gateway vortex-ban`.

## Set or change the owner password
On the VPS, with the password in the environment (do not put it in shell history if you can avoid it):

```bash
VORTEX_OWNER_PASSWORD='…' dolphin-gateway set-owner-password
systemctl restart dolphin-gateway
```

Only the Argon2id PHC string is written under `/etc/dolphin/gateway/owner.phc` (mode 0600).
