# Vortex agents — one creator, multiple ways to work

Create or edit every agent in **Agents → New agent** on macOS, Windows or
Linux. The older server-agent API and existing agent records remain
compatible; they are not separate workflows for new users.

A Vortex agent has a **name**, **instructions**, a **standing task** (optional
for manual-only agents), **permissions**, a **model strategy**, **execution
location**, a **run frequency**, and an **optional provider/API key**.
Credentials are stored separately from agent JSON, never in prompts.

## Intelligence

- **Auto** selects a permitted specialist appropriate to the task
  (coding, reasoning, writing, vision, or general work). It can only use
  models actually listed as available to this gateway key.
- **Mix** uses a second permitted model to plan and a specialist executor
  to work with real tools. Tool access belongs to the executor alone; a
  planner cannot grant permissions.
- **Single** uses the selected model. Local agents may use a personal
  OpenAI, xAI, OpenRouter, Ollama or other compatible API key. Native shims
  for some external providers require their corresponding compatible
  endpoint; don't assume an arbitrary provider accepts OpenAI calls.

Tool-backed work has a bounded step budget. The system records what tools
actually did and distinguishes verified success, pending approvals,
denials, errors, and exhausted budgets. Models cannot guarantee completion
of an unknown command just by generating a confident answer.

## Execution locations

| Location | Behavior | Requirements |
| --- | --- | --- |
| Local background | Work on the computer hosting Vortex without stealing the user's existing input focus | Vortex must be running, local permissions and per-agent tool grants |
| Vortex server | Recurring model-only reasoning continues when the desktop app is closed | Online gateway and model/chat authorization |
| Cloud PC | Authenticated job leases delegated to a separate Linux worker for bounded file, shell and Playwright DOM-browser actions | An approved running Cloud PC, installed worker, shared scoped key, explicit worker+agent grants |

Cloud PC worker setup and kill semantics: [CLOUD-PC-AGENT-WORKER.md](CLOUD-PC-AGENT-WORKER.md).

Manual runs, intervals from 30 seconds to 24 hours, and **Nonstop** mode
are supported. Nonstop has a minimum delay to avoid runaway loops. Cloud PC
worker task polling requires a live Cloud PC; instances that shut down when
idle will stop their agents. Persistent *server* agents do not automatically
acquire remote browser or shell access.

## Permissions and Stop

Tool categories are individually grantable. Filesystem reads, writes, shell,
browser and external plugins remain independently controlled. Automatic
writes require both the agent's explicit authorization **and** the host
machine's separate opt-in. Remote Cloud PC shell, write and browser actions
add a third requirement: the worker machine must enable that category.

**STOP ALL AGENTS** persists a local pause, interrupts active local work
and child commands, revokes remembered local approval, and asks the gateway
to revoke every remote schedule/lease for the account. This cannot undo
actions that completed before Stop. If the gateway is unreachable, the UI
reports that remote cancellation was not verified. Resetting Stop never
automatically restarts paused agents.

For browser tasks, use a verified DOM browser worker and a dedicated browser
profile. Foreground keyboard macros must never guess which search box,
editor or browser tab is focused. No account password should be stored in a
model instruction, log, source file or agent definition.

## Leader-led teams

**New team workspace** creates a group chat with at least two agents/models
and **one designated leader**. Choose a project workspace to keep the team's
instructions and reference context separate from other chats.

The leader plans explicit assignments, team members handle their tasks using
their individually granted tools, and the leader reviews their actual outputs
before writing a final report. A team cannot elevate a member's model grants,
filesystem access or local/remote execution privileges. Jobs waiting for a
human approval remain pending in Activity rather than being marked completed.

Existing simple party chats and single-agent chats remain readable.

## API

The authenticated gateway retains the existing:

- `GET /v1/agents` and `POST /v1/agents`
- `GET /v1/agents/{id}`, `DELETE /v1/agents/{id}`
- `POST /v1/agents/{id}/toggle`
- `POST /v1/agents/{id}/chat`

New explicit stop and worker endpoints:

- `POST /v1/agents/stop-all`
- `GET /v1/agents/worker/online`
- `POST /v1/agents/worker/heartbeat`
- `POST /v1/agents/worker/claim`
- `POST /v1/agents/worker/status`
- `POST /v1/agents/worker/report`

Cloud PC worker endpoints require a valid API key with chat+cloudpc access,
current model grants, and a valid time-limited worker lease. A disconnected
worker cannot be treated as an authorized remote computer. Agent tasks are
never a bypass for key restrictions, model policies or revoked permissions.
