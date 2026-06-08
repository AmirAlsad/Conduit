# Conduit Engine

**Make your existing voice agent reachable as a native phone call.**

Conduit is a "dumb pipe" iOS calling app: it places a voice **agent** as a real
CallKit phone call, and the **agent owns the brain** (model, voice, persona,
memory). This repo is the *agent side* — the always-on service that hands the app
a room to join and runs your agent in it.

You already have a voice agent (or will build one). **This repo is not a tutorial
on building one** — it's the reference for **connecting yours to Conduit**: the
small contract your agent must satisfy, and a working engine that satisfies it.
`loopback` and `live` are reference agents you replace with your own.

> New here? Read **[Bring your own agent](./docs/bring-your-own-agent.md)** — the
> 3-step integration plus the contracts, with code pointers. The rest of this
> README is the overview and operational reference.

---

## How your agent fits

```
                ┌──────────────────── your always-on engine (this repo) ─────────────────────┐
 iOS app  ──────┤  FastAPI dispatcher (app/)   hands the app a room+token, then               │
 (or test client)│   • POST /connect            spawns YOUR agent into the room  ───► bot/ ────┼──► Daily /
 ───────────────┤   • POST /credentials        (one subprocess per call)         your agent    │    LiveKit
 joins the room ─┤   • POST /webhooks/{daily,livekit}                              runs here     │    Cloud SFU
                └──────────────────────────────────────────────────────────────────────────────┘
                          the app and your agent meet in a Daily/LiveKit Cloud room
```

- **Dispatcher** (`app/`) — always-on FastAPI. Mints room credentials, and
  dispatches your agent into a room at call time. You rarely touch this.
- **Bot** (`bot/`) — where **your agent runs**. It's handed a room, a token, a
  transport, and an `agent_id`, builds the transport, and runs your pipeline. It's
  **launch-agnostic**: it never learns whether a pairing call, a webhook, or a dev
  script started it.

Your agent dials **out** to the cloud SFU, so the only inbound surface is the
HTTPS dispatcher. No inbound UDP / TURN / media termination to operate.

---

## Bring your own agent

Three steps (full walkthrough in **[docs/bring-your-own-agent.md](./docs/bring-your-own-agent.md)**):

**1. Write a pipeline factory** — `build(transport) -> BotBuild`. If you already
have a Pipecat bot, this *is* your pipeline; just return the worker.

```python
# bot/pipelines/myagent.py
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from bot.buildresult import BotBuild

def build(transport) -> BotBuild:
    pipeline = Pipeline([transport.input(), *your_processors, transport.output()])
    worker = PipelineWorker(pipeline)          # RTVI on by default — see contracts
    return BotBuild(worker=worker, on_ready=None)   # on_ready: optional greet
```

**2. Register it** (two one-line entries):

```python
# bot/runtime.py
_BUILDERS = {"loopback": loopback.build, "live": live.build, "myagent": myagent.build}

# app/agents.py
AGENTS["myagent"] = AgentConfig("myagent", default_transport="daily",
                                description="...", required_settings=("MY_KEY",))
```

**3. Call it** — `POST /connect {"agent_id": "myagent", "transport": "daily"}`.

You do **not** write transport, dispatch, teardown, greet, or RTVI plumbing — the
provided entrypoint (`bot/runtime.py:run_bot`) wires those around your pipeline.

---

## The contract your agent must satisfy

Three things, all handled for you if you build on the provided entrypoint — but
they're requirements, so a from-scratch agent must honor them:

1. **Transport-agnostic pipeline.** You're handed a ready `transport` (Daily or
   LiveKit). Use `transport.input()` / `transport.output()`; the same pipeline runs
   on both. Don't hardcode a transport.
2. **RTVI speaking-state — the glow contract.** The app's listening/speaking glow
   is driven *entirely* by RTVI speaking-state events. `PipelineWorker` emits them
   automatically (RTVI is on by default). **An agent that omits RTVI leaves the glow
   dark** — this is the one requirement people miss.
3. **Reconnection-safe teardown.** Do **not** exit the instant the human drops —
   the iOS client reconnects with backoff through tunnels/dead-zones. Stay for a
   grace window so a reconnecting caller resumes mid-conversation, and end
   immediately only on an explicit hangup signal. `run_bot` + `bot/teardown.py` do
   this for you (`HUMAN_ABSENT_GRACE_SECS`; RTVI `{"type":"end-call"}` ends at once).
   See [Teardown](#teardown-reconnection-and-the-end-call-signal).

---

## The connection contract (what the app receives)

`/connect` and `/credentials` both return this shape (internal, not a frozen
public spec yet):

```jsonc
{
  "transport": "daily" | "livekit",
  "connection": {
    // daily:   { "room_url": "...", "token": "..." }
    // livekit: { "url": "wss://...", "token": "...", "room_name": "..." }
  },
  "agent_id": "loopback" | "live" | "<yours>",
  "expires_at": "<ISO8601 | null>"   // short for pairing, long/null for direct
}
```

Two ways the app gets here:
- **Pairing** (`POST /connect`) — engine creates a room, dispatches your agent into
  it *now*, returns short-lived creds. The agent is waiting as the app joins.
- **Direct** (`POST /credentials`) — engine returns stable, long-lived creds
  (pasted into the app once). At call time the app joins directly and an SFU
  **webhook** dispatches your agent. See **[docs/direct-mode.md](./docs/direct-mode.md)**.

A token's expiry gates only the **initial** connect, never reconnects — a
long-lived direct token won't sabotage reconnection-with-backoff.

---

## Reference agents (examples to copy)

- **`loopback`** — echoes your audio back. No model, no keys, ~zero latency. It's
  the diagnostic for the *pipe* (CallKit↔WebRTC, route switching, mute, speaker
  default, raw quality) — if something's wrong here, it's the channel, not the
  agent. (`LOOPBACK_BOT_SPEAKING=false` for a pure passthrough.)
- **`live`** — a complete reference agent that satisfies all three contracts:
  `STT → LLM → TTS` (Deepgram · Groq · Cartesia by default), RTVI speaking-state,
  greet-on-connect, barge-in, reconnection-safe teardown. **Copy this** as the
  starting point for your own. Swap any stage in `bot/pipelines/live.py`
  (TTS is also runtime-selectable via `TTS_PROVIDER`).

---

## Quickstart (see the reference agent on a call)

```bash
uv sync
cp .env.example .env     # fill the keys you have; see .env.example for what each feature needs
```

**Talk to an agent locally (no dispatcher):**
```bash
uv run python -m bot.bot                       # open http://localhost:7860/client
CONDUIT_AGENT=live uv run python -m bot.bot     # the live agent (default is loopback)
```

**The dispatcher + a pairing call:**
```bash
uv run uvicorn app.main:app --reload           # http://localhost:8000
curl -s -X POST http://localhost:8000/connect \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"loopback","transport":"daily"}'   # ← swap in your own agent_id
```
Paste the returned JSON into the [web test client](./clients/web) (`npm run dev`)
to join and hear the agent. `uv run pytest` runs the suite.

> macOS note: this is handled for you (`SSL_CERT_FILE` → certifi in `app/config.py`),
> but be aware the python.org/uv Python trusts no system CAs by default, which would
> otherwise break every outbound TLS call (Daily, Deepgram, etc.).

---

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/connect` | bearer | Pairing: create creds, dispatch agent now, return creds |
| POST | `/credentials` | bearer | Direct: create stable creds, register room, return creds |
| POST | `/webhooks/daily` | signature | Daily participant.joined → idempotent dispatch |
| POST | `/webhooks/livekit` | signature | LiveKit participant_joined → idempotent dispatch |
| POST | `/admin/disconnect` | bearer | Force-end an agent in a room (drop test) |
| GET  | `/health` | none | Liveness / keep-warm |

Bearer = `Authorization: Bearer $ENGINE_API_KEY` (the dispatcher **fails fast on
boot if it's unset**). Webhooks authenticate by signature (the caller is the SFU).
Body for `/connect` and `/credentials`: `{"agent_id": "...", "transport":
"daily"|"livekit"}` (transport optional → agent/engine default). Body for
`/admin/disconnect`: `{"room_key": "<room>"}` (the room name from the payload).

---

## Teardown, reconnection, and the end-call signal

The one place generic agent examples get it wrong for this client. The common
pattern cancels the pipeline the instant the human leaves — which **breaks**
Conduit's headline feature, since the iOS client drops media in tunnels/dead-zones
and reconnects with backoff while CallKit still shows the call up. So:

- On the human leaving, a **`HUMAN_ABSENT_GRACE_SECS`** timer starts; teardown only
  fires if no human rejoins. The agent stays, so the room is non-empty and a
  reconnecting caller resumes mid-conversation.
- An **explicit end signal** ends a real hangup at once: the client sends RTVI
  `{"type": "end-call"}` (handled via `on_client_message`), or hits
  `POST /admin/disconnect`. Without it, every hangup harmlessly waits out the window.

> **`HUMAN_ABSENT_GRACE_SECS` is a shared constant with the client team** — it must
> be ≥ the client's total reconnect-with-backoff budget, and no longer (your agent
> is a billed participant during the window).

## Tuning knobs (for the reference `live` agent)

- **`VAD_STOP_SECS`** (default `0.2`) — endpointing delay. Turn-end uses Pipecat's
  default **Smart Turn v3** (auto-applied; you'll see it load at startup). Raise this
  to give a thinking-partner more silence tolerance, at some latency cost.
- **`TTS_PROVIDER`** — `cartesia` (default) | `deepgram` | `groq`; each reuses that
  provider's key. The agent's required-keys check follows it.
- **`HUMAN_ABSENT_GRACE_SECS`** — see above.

See `.env.example` for the full list and which feature needs which key.

---

## Deploy (your own way)

A single always-on web process; only inbound surface is HTTPS. Keep it a **single
process** (see caveats) and **always-on** (no app-sleeping — it must answer
webhooks and `/connect` without a cold start).

- **Docker / any host**: a [`Dockerfile`](./Dockerfile) is provided (Python 3.12 +
  uv, `uv sync --frozen`, binds `${PORT:-8000}`). `docker build -t conduit . &&
  docker run -p 8000:8000 --env-file .env conduit`. `.dockerignore` keeps
  `.venv`/`.env`/`node_modules` out — inject secrets via your platform, never the image.
- **Railway**: `railway.json` sets the start command + `/health` check. **Disable
  Serverless / App Sleeping.**

Then set the env vars on the platform, and **for direct mode only** register the
SFU webhook **once** against your public URL (persists across redeploys):
```bash
uv run python scripts/daily_webhook.py register --base-url https://<your-public-host>
```
Full deploy + webhook details: **[docs/direct-mode.md](./docs/direct-mode.md)**.

---

## ⚠️ Operational caveats

- **In-memory registry is not redeploy-safe.** Direct-mode rooms live in process
  memory; a restart/redeploy orphans them (webhook arrives → room unrecognized → no
  agent dispatched → call connects to silence). The `Registry` interface in
  `app/registry.py` is the swap seam — wire Postgres/Redis before relying on direct
  mode in production. (Pairing is unaffected.)
- **Single dispatcher process only.** Idempotency uses the in-memory registry +
  per-room asyncio locks, which serialize only within one event loop. Don't run
  replicas or `--workers > 1` until the registry is shared.
- **Daily webhooks** need a credit card on the Daily account and fire domain-wide;
  the engine filters to registered rooms and ignores the agent's own join.
- **No Pipecat JS LiveKit client** yet — the web test client drives **Daily only**.
  Use `meet.livekit.io` / the LiveKit Agents Playground, or the iOS app, for LiveKit.
- **Redeploys kill in-flight agents** and drop active calls — deploy when quiet.

## Design & scope

Design rationale: [`voice-agent-bot-engine-plan.md`](./voice-agent-bot-engine-plan.md).
**Out of scope (fast-follows):** SmallWebRTC/TURN, native `livekit-agents`
token-encoded dispatch, freezing the public connection spec, a persistent registry
store (interface is in place).
