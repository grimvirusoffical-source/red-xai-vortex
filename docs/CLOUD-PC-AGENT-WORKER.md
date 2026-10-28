# Vortex Cloud PC agent worker

The Vortex gateway handles model inference and queues background requests. A
**separately installed worker** performs shell/file/browser actions inside a
user-authorized Cloud PC. It never takes control of the user's Mac or Windows
foreground keyboard or invents UI actions from model text.

## Current design

- **Local background:** Mac, Windows, or Linux agents work while the Vortex
  desktop app is running, with their scoped local tools and permissions.
- **Vortex server:** model-only persistent agents continue when Vortex is
  closed. They are not allowed to run server-side shell commands or browser
  actions. Server runs still obey API-key chat/model authorization.
- **Cloud PC:** an opted-in Linux process runs on the user's approved Cloud PC,
  announces availability to the gateway, claims short-lived jobs and uses only
  the agent-granted permissions **and** machine-owner opt-ins. Existing
  connections are not assumed merely because the Cloud PC website is reachable.

A Cloud PC that shuts down after inactivity will stop its agent worker. To run
continuously, the Cloud PC instance and its worker service need to stay running;
Vortex cannot override the host's idle-shutdown policy. Requests are queued
again after a worker reconnects.

## Install inside your own Cloud PC

Use a *non-root* account in the already authorized isolated Linux desktop.
Copy only `scripts/cloudpc-agent-worker.py` from the reviewed Vortex release,
then create a dedicated private workspace:

```bash
mkdir -p "$HOME/VortexAgentWork" "$HOME/.config/vortex-worker"
chmod 700 "$HOME/VortexAgentWork" "$HOME/.config/vortex-worker"

# Optional browser tools; install these INSIDE Cloud PC, not on the Mac.
python3 -m pip install --user playwright
python3 -m playwright install chromium
```

In the Cloud PC's local secret manager or an owner-readable-only file, provide:

```bash
export VORTEX_API_BASE="https://YOUR-VORTEX-GATEWAY/v1"
export VORTEX_AGENT_KEY="YOUR_SEPARATELY_CREATED_SCOPED_VORTEX_API_KEY"
export VORTEX_WORKER_ID="cloudpc-your-private-workspace"
export VORTEX_WORKSPACE_DIR="$HOME/VortexAgentWork"
export VORTEX_BROWSER_PROFILE_DIR="$HOME/.config/vortex-worker/chromium-profile"

# All execution modifications are OFF unless the machine owner enables them.
export VORTEX_ALLOW_WRITES="0"
export VORTEX_ALLOW_SHELL="0"
export VORTEX_ALLOW_BROWSER="0"
export VORTEX_BROWSER_ALLOW_DOMAINS="example.com"
```

The gateway key needs **chat + cloudpc scopes** and permission for the
configured agent model. Keep it secret, use an expiring/revocable key and
never paste it into an agent's instructions, a chat, or a ticket. Use a
restricted file mode of `0600` if an environment file is unavoidable.
No website or Discord password belongs in the worker configuration.

With those variables configured, run:

```bash
python3 scripts/cloudpc-agent-worker.py
```

The process remains on the Cloud PC even when the local Vortex app closes, for
as long as the Cloud PC itself stays running. Use your OS's user-level service
manager to start/restart the worker; do not run it as root.

## Browser workflow

Enable `VORTEX_ALLOW_BROWSER=1` on the Cloud PC and explicitly grant
`browser` to the desired agent. If the agent will click/fill pages, also turn
on the agent's **Allow unattended actions** setting in Vortex. This needs
both machine consent and user-issued agent consent.

The worker creates a **separate Playwright Chromium profile**. For an account
that needs interactive login, start the worker temporarily with
`VORTEX_BROWSER_HEADLESS=0` inside your own remote desktop, sign in directly
through that Chrome window, exit that worker, and restart headlessly. The
agent itself must never receive account passwords.

The model must use `browser_tabs`, `browser_select_tab`,
`browser_navigate`, and `browser_observe` to get verifiable element IDs
before `browser_fill` or `browser_click`. Inputs labeled as search/address
fields are explicitly blocked from fill operations. The worker permits at
most one outbound submit per job and has a short cooldown. A click is
reported as an attempted click, not proof that a recipient received a message.

Playwright browser control and logged-in sessions depend on website and
browser behavior. The worker does not bypass CAPTCHAs, MFA, account bans or
website rate limits.

## Emergency stop and lifecycle

Vortex's **STOP ALL AGENTS** pauses agent schedules and revokes outstanding
Cloud PC worker leases. The worker checks its lease before every tool call
and periodically during shell commands, and kills its own subprocess group
when the lease is revoked. It will stop reporting after the gateway rejects
an expired/stopped lease.

As with any distributed system, an action already completed before Stop
cannot be undone; network outages can delay propagation. Avoid restarting
non-idempotent sends/writes automatically. A worker's report is attributed
to that worker; it is not independent confirmation that an external website
received an interaction.

When a background job cannot be authorized, Vortex reports the actual model,
key, lease, worker or approval error instead of silently substituting local
computer control.

## Limitations

- This is a worker *implementation*, not an automatic installer or a live
  deployment to a Cloud PC. Operators must provision the approved worker.
- OpenAI-compatible external-model APIs remain a **local** agent choice unless
  a matching remote provider adapter is explicitly installed.
- The verified Cloud PC worker operates in its own Linux workspace and
  dedicated Chromium profile; it does not attach to your Mac's existing
  foreground Chrome tabs.
- Job leases are limited; interrupted writes/sends are not guaranteed
  exactly-once. Automation requiring such guarantees needs application-level
  idempotency or acknowledgments.
