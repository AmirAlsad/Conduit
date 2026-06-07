# Conduit Backend — Voice Agent Bot Engine

A Python engine that hosts voice agents reachable over WebRTC through **Daily**
and **LiveKit Cloud**. It is the agent side of a "dumb pipe" iOS calling app: the
**agent owns the brain** (model, voice, persona); the app is a faithful audio
channel. It exists to (1) give the iOS CallKit/WebRTC client a real agent to test
against, and (2) be the reference implementation third parties copy.

Full design rationale: [`voice-agent-bot-engine-plan.md`](./voice-agent-bot-engine-plan.md).

## Architecture

One codebase, two runtime roles:

```
                 ┌─────────────────────────── Railway (always-on) ───────────────────────────┐
 app POST /connect ─┐                                                                          │
 (pairing)          ├──►  FastAPI dispatcher (app/)  ──► dispatch core ──► spawns ──► bot/ ────┼──► Daily / LiveKit
 app joins fixed    │      • POST /connect /credentials   (idempotent)     subprocess          │     Cloud SFU
 room (direct) ─► SFU ──► POST /webhooks/{daily,livekit} ─┘                 (one per call)      │
                    │      • POST /admin/disconnect, GET /health                                │
                    └──────────────────────────────────────────────────────────────────────────┘
```

- **Dispatcher** (`app/`) — always-on FastAPI. Mints credentials, receives
  webhooks, dispatches bots. Never sleeps.
- **Bot** (`bot/`) — a **launch-agnostic** Pipecat pipeline. One subprocess per
  call; joins one room, runs, exits when the room empties. It receives a room, a
  token, a transport, and an agent id — and never learns who launched it.

The bot dials **out** to the cloud SFU, so the only inbound surface is the HTTPS
dispatcher + webhooks. No inbound UDP / TURN / media termination.

## Layout

```
app/   dispatcher: config, auth, models, registry, agents, dispatch, provisioning, routes/, transports/
bot/   launch-agnostic bot: bot.py (entry), runtime.py, teardown.py, transport_factory.py, pipelines/{loopback,live}.py
clients/web/   Voice UI Kit Console test client (Daily)
tests/         unit tests (fakes, no network)
```

## Setup

```bash
uv sync
cp .env.example .env     # fill the keys you have (see below)
```

The reference `live` stack is **Deepgram STT · Groq LLM · Cartesia TTS** (each a
one-line swap in `bot/pipelines/live.py`). Every secret is optional at load time —
each feature validates the keys it needs at point of use, so partial setups work
(you can run `loopback` with only Daily creds).

## Run & verify (local)

### 1. The bot in isolation (dev runner)

```bash
uv run python -m bot.bot               # all transports; open http://localhost:7860/client
CONDUIT_AGENT=live uv run python -m bot.bot   # use the live agent instead of loopback
```

Talk in the browser. `loopback` echoes your voice; `live` greets you and converses.

### 2. The dispatcher + pairing

```bash
uv run uvicorn app.main:app --reload   # http://localhost:8000

curl -s -X POST http://localhost:8000/connect \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"loopback","transport":"daily"}'
```

Paste the returned JSON into the [web test client](./clients/web) (`npm run dev`)
and connect — two-way audio with the RTVI glow.

### 3. Direct mode (provision once, dispatch via webhook)

```bash
# Provision a stable room + long-lived token (paste into the app once):
curl -s -X POST http://localhost:8000/credentials \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"live","transport":"daily"}'
```

At call time the app joins that room directly; the SFU fires a participant-joined
webhook and the engine dispatches the bot reactively. To test locally, expose the
dispatcher with a tunnel (`ngrok http 8000`) and register the webhook against it
(see *Deploy* below).

### 4. Tests

```bash
uv run pytest
```

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/connect` | bearer | Pairing: create creds, dispatch bot now, return creds |
| POST | `/credentials` | bearer | Direct: create stable creds, register room, return creds |
| POST | `/webhooks/daily` | signature | Daily participant.joined → idempotent dispatch |
| POST | `/webhooks/livekit` | signature | LiveKit participant_joined → idempotent dispatch |
| POST | `/admin/disconnect` | bearer | Force-end a bot in a room (drop test) |
| GET  | `/health` | none | Liveness / keep-warm |

Bearer = `Authorization: Bearer $ENGINE_API_KEY`. Webhooks authenticate by
signature (the caller is the SFU). Body for `/connect` and `/credentials`:
`{"agent_id": "loopback"|"live", "transport": "daily"|"livekit"}` (transport
optional → agent/engine default).

### Connection contract (internal, not a frozen public spec)

```jsonc
{
  "transport": "daily" | "livekit",
  "connection": {
    // daily:   { "room_url": "...", "token": "..." }
    // livekit: { "url": "wss://...", "token": "...", "room_name": "..." }
  },
  "agent_id": "loopback" | "live",
  "expires_at": "<ISO8601 | null>"   // short for pairing, long/null for direct
}
```

A token's expiry gates only the **initial** connect, never reconnects — a
long-lived direct token won't sabotage reconnection-with-backoff.

## Agents

- **`loopback`** — `input → output` passthrough. No model, no keys, zero added
  latency. Isolates the pipe (CallKit↔WebRTC, route switching, mute, speaker
  default, quality). Optionally synthesizes bot-speaking RTVI state while echoing
  (`LOOPBACK_BOT_SPEAKING=false` for the pure pipe).
- **`live`** — `input → STT → LLM → TTS → output` with RTVI. Greets on connect,
  barge-in on. Swap a provider by editing one line in `bot/pipelines/live.py`.

**RTVI is a contract, not a nicety.** The client's listening/speaking glow is
driven entirely by RTVI speaking-state events (emitted automatically by the
`live` pipeline). A custom agent that omits RTVI leaves the glow dark.

## Key knobs

- **`VAD_STOP_SECS`** (default `0.2`) — the endpointing delay. Smart-Turn is the
  default stop strategy and was trained on 0.2; **raise it** to give a
  thinking-partner more silence tolerance, at some latency cost. The single most
  important conversational tuning parameter.
- **`HUMAN_ABSENT_GRACE_SECS`** (default `60`) — see below.

## Teardown, reconnection, and the end-call signal (important)

Pipecat's common pattern cancels the pipeline the instant the human leaves — which
**breaks** this client's headline feature. The iOS client drops media in
tunnels/dead-zones and reconnects with backoff while CallKit shows the call up. So
this engine instead:

- On the human leaving, starts a **`HUMAN_ABSENT_GRACE_SECS`** timer and only
  tears down if no human rejoins. While the bot stays, the room is non-empty and a
  reconnecting client resumes mid-conversation.
- Honors an **explicit end signal** so a real hangup ends at once: the client
  sends an RTVI message `{"type": "end-call"}` (handled via `on_client_message`),
  or hits `POST /admin/disconnect`. Without it, every hangup harmlessly waits out
  the window.

> **`HUMAN_ABSENT_GRACE_SECS` is a shared constant with the client team.** It must
> be ≥ the client's total reconnect-with-backoff budget, and no longer (the bot is
> billed during the window).

## ⚠️ Operational caveats

- **In-memory registry is not redeploy-safe.** Direct-mode rooms are recorded in
  process memory; a restart/redeploy orphans every provisioned room (the webhook
  arrives, the engine doesn't recognize it, no bot is dispatched, the call connects
  to silence). The `Registry` interface in `app/registry.py` is the seam — wire a
  Postgres/Redis impl before relying on direct mode in production. (Pairing is
  unaffected; it creates everything within one request.)
- **Daily webhooks** require a credit card on the Daily account and fire
  **domain-wide** (every room). The engine filters to registered rooms and ignores
  the bot's own join.
- **No Pipecat JS LiveKit client** yet, so the web test client drives **Daily
  only**. Use `meet.livekit.io` / the LiveKit Agents Playground, or the iOS app,
  to test LiveKit.
- **Redeploys kill in-flight bots** and drop active calls — deploy when quiet.

## Deploy to Railway (follow-up — not done in the local-first pass)

1. Create a service from this repo. `railway.json` sets the start command and
   `/health` check; Nixpacks builds the uv project.
2. **Disable Serverless / App Sleeping** on the service (dashboard → Settings) —
   the dispatcher must receive webhooks and serve `/connect` without a cold start.
3. Set env vars from `.env` (`ENGINE_API_KEY`, `DAILY_*`, `LIVEKIT_*`, provider
   keys, `PUBLIC_BASE_URL`, webhook secrets).
4. Register webhooks against `PUBLIC_BASE_URL`:
   - **Daily**: `POST https://api.daily.co/v1/webhooks` with
     `eventTypes: ["participant.joined"]` and `url: $PUBLIC_BASE_URL/webhooks/daily`;
     store the returned `hmac` as `DAILY_WEBHOOK_SECRET`.
   - **LiveKit**: add `$PUBLIC_BASE_URL/webhooks/livekit` in the project's webhook
     settings (verification uses your `LIVEKIT_API_KEY`/`SECRET`).

## Out of scope (fast-follows)

SmallWebRTC/TURN transport, native `livekit-agents` token-encoded dispatch,
freezing the public connection spec, curated default agents, persistent registry
store (interface is in place).
