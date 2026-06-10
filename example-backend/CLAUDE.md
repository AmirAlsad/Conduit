# CLAUDE.md — example-backend

Guidance for Claude Code when working **inside `example-backend/`**. This subtree is
independent from the iOS app at the repo root; the app's build/test instructions do
**not** apply here.

## What this is

**Conduit Engine** — the *reference backend* a developer self-hosts so their voice
agent is reachable from the Conduit iOS app. It is **not a service Conduit operates**:
each developer runs it under their own accounts and API keys, which is why the app's
"no backend of ours" principle still holds. `loopback` and `live` are reference agents
you replace with your own.

Start with [`README.md`](./README.md) and
[`docs/bring-your-own-agent.md`](./docs/bring-your-own-agent.md).

## Stack & layout

- **Python 3.12, `uv`-managed, FastAPI + Pipecat.**
- `app/` — always-on FastAPI **dispatcher**: mints room credentials, dispatches an
  agent into a room at call time, handles Daily/LiveKit webhooks.
- `bot/` — launch-agnostic **bot engine** where the agent pipeline runs.
- `clients/web/` — a Vite/React test client (Daily only).
- `tests/` — pytest suite (`pytest-asyncio`).

## Commands

- Install: `uv sync`
- Test: `uv run pytest`
- Talk to an agent locally (no dispatcher): `uv run python -m bot.bot`
  (`CONDUIT_AGENT=live` for the full reference agent)
- Run the dispatcher: `uv run uvicorn app.main:app --reload`
- Mint direct-mode creds to paste into the app: `uv run python scripts/provision.py --transport daily|livekit`
- Register the Daily direct-mode webhook: `uv run python scripts/daily_webhook.py register --base-url <host>`
  (LiveKit's webhook is dashboard-only — see `docs/direct-mode.md`)
- Ring the device (inbound call; needs the `APNS_*` vars): `uv run python scripts/ring.py --agent <id> [--inline]`
- Print a conduit:// pairing link + QR for the app: `uv run python scripts/pair.py --agent <id> [--no-key] [--inbound]`
  (the link embeds `ENGINE_API_KEY` unless `--no-key` — treat it like the key; shape is a contract with the app's `DeepLinkParser`)

Endpoint notes: per-agent routes (`POST /connect/{agent_id}`, `POST
/credentials/{agent_id}`) are the canonical shape — the app sends no agent_id;
the bare routes default to `loopback`. LiveKit connection payloads carry
`room_url` (canonical, what the app reads) plus `url` as a deprecated alias.
**SmallWebRTC** (`{"transport":"smallwebrtc"}`) is pairing-only: `/connect`
mints a short-lived offer token and returns `room_url` = the engine's own
`POST/PATCH /webrtc/{agent_id}/offer` route, where the bot runs as an **asyncio
task in the dispatcher process** (no room, no subprocess; `run_bot(...,
handle_sigint=False, handle_sigterm=False)` so uvicorn keeps its signal
handlers). Media is UDP peer-to-peer — LAN/self-hosted only, never Railway. For
LAN testing run uvicorn with `--host 0.0.0.0` and build the pair.py link from
the Mac's LAN IP.

## Conventions & guardrails

- **Secrets via env only.** Copy `.env.example` → `.env`; never commit a real key,
  `.env`, or an APNs `.p8`. Same hard rule as the app.
- This backend implements the contracts the app depends on — keep it in sync with the
  repo's [`docs/CONNECTION_CONTRACT.md`](../docs/CONNECTION_CONTRACT.md) (outbound) and
  [`docs/INBOUND_CALLS.md`](../docs/INBOUND_CALLS.md) (agent-initiated inbound).
- Single always-on process (replicas are still unsafe — dispatch idempotency is
  per-event-loop). The registry is SQLite at `REGISTRY_DB_PATH`; it survives
  redeploys only on durable storage (volume) — read the README's operational
  caveats. Never persist active-bot pids.
