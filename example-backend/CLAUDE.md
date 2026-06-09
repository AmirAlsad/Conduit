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

Endpoint notes: per-agent routes (`POST /connect/{agent_id}`, `POST
/credentials/{agent_id}`) are the canonical shape — the app sends no agent_id;
the bare routes default to `loopback`. LiveKit connection payloads carry
`room_url` (canonical, what the app reads) plus `url` as a deprecated alias.

## Conventions & guardrails

- **Secrets via env only.** Copy `.env.example` → `.env`; never commit a real key,
  `.env`, or an APNs `.p8`. Same hard rule as the app.
- This backend implements the contracts the app depends on — keep it in sync with the
  repo's [`docs/CONNECTION_CONTRACT.md`](../docs/CONNECTION_CONTRACT.md) (outbound) and
  [`docs/INBOUND_CALLS.md`](../docs/INBOUND_CALLS.md) (agent-initiated inbound).
- Single always-on process; the in-memory registry is **not** redeploy-safe — read the
  README's operational caveats before relying on direct mode.
