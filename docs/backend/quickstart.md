# Example backend — quickstart

The reference backend lives in
[`example-backend/`](https://github.com/AmirAlsad/Conduit/tree/main/example-backend)
— a self-contained **FastAPI + Pipecat** project ("the engine") that makes your
voice agent reachable from the Conduit app. You self-host it under your own API
keys; it is not a service anyone operates for you.

```
                ┌─────────────── your always-on engine ────────────────┐
 Conduit app ───┤  FastAPI dispatcher (app/)  mints room credentials,   │
                │   POST /connect/{agent}     spawns YOUR agent into    │──► Daily /
                │   POST /credentials/{agent} the room (bot/, one       │    LiveKit
                │   POST /webhooks/…          subprocess per call)      │    Cloud SFU
                └────────────────────────────────────────────────────────┘
                     the app and your agent meet in a Daily/LiveKit room
```

Two reference agents are included:

- **`loopback`** — echoes your audio back. **Zero AI-provider keys**, ~zero
  latency; the diagnostic for the pipe itself. This is the default agent.
- **`live`** — a complete STT → LLM → TTS agent (Deepgram · Groq · Cartesia by
  default) with greeting, barge-in, and reconnection-safe teardown. Copy it as the
  starting point for your own.

## 1. Install and configure

```bash
cd example-backend
uv sync
cp .env.example .env
```

Fill in only the keys for what you run (`.env.example` annotates every variable):

| You want | You need |
|---|---|
| `loopback` over Daily pairing | `ENGINE_API_KEY` + `DAILY_API_KEY` |
| Anything over LiveKit | + `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL` |
| The `live` agent | + `DEEPGRAM_API_KEY`, `GROQ_API_KEY`, `CARTESIA_API_KEY` |
| Direct mode (either SFU) | a public URL + the SFU webhook ([details](direct-mode.md)) |

Both transports run the **same pipelines with the same keys** — LiveKit only adds
the `LIVEKIT_*` trio; the agent's STT/LLM/TTS keys are shared.

## 2. Talk to an agent locally (no dispatcher)

```bash
uv run python -m bot.bot                       # loopback — open http://localhost:7860/client
CONDUIT_AGENT=live uv run python -m bot.bot    # the full reference agent
```

## 3. Run the dispatcher and make a pairing call

```bash
uv run uvicorn app.main:app --reload           # http://localhost:8000

curl -s -X POST http://localhost:8000/connect/loopback \
  -H "Authorization: Bearer $ENGINE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"transport":"daily"}'
```

The URL names the agent; the response is the
[connection contract](../CONNECTION_CONTRACT.md) shape — a `room_url` + `token`
the caller joins, with the agent already dispatched into the room.

## 4. Point the Conduit app at it

Deploy the engine to a public HTTPS host ([Deploy](deploy.md)), then the fast
path is a **QR code**:

```bash
uv run python scripts/pair.py --agent live --base-url https://your-host
```

Scan the printed QR with the iPhone Camera app — Conduit opens with the agent
pre-filled (name, transport, endpoint, key); just tap Save. Add `--inbound` to
also enable "Let this agent call me".

!!! warning "The link embeds your API key by default"
    One scan = fully configured, but the link (and the QR) is then as secret as
    `ENGINE_API_KEY` itself. Pass `--no-key` to leave it out and type the key in
    the app instead.

Or fill **Add Agent → Connection** by hand:

- **Pairing endpoint** → `https://your-host/connect/live` (or any agent id)
- **API key** → your `ENGINE_API_KEY`
- **Transport** → Daily or LiveKit, matching the keys you configured

Tap **Test Connection** — it walks the stages (pairing endpoint → credentials →
transport → agent ready) and names the step that fails — then call.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/connect/{agent_id}` | bearer | Pairing: mint per-call creds, dispatch the agent now |
| POST | `/connect` | bearer | Same; agent from body or default (`loopback`) |
| POST | `/credentials/{agent_id}` | bearer | Direct: mint stable creds, dispatch later via webhook |
| POST | `/credentials` | bearer | Same; agent from body or default (`loopback`) |
| POST | `/webhooks/daily`, `/webhooks/livekit` | signature | participant-joined → idempotent dispatch |
| POST | `/admin/disconnect` | bearer | Force-end an agent in a room |
| GET | `/health` | none | Liveness / keep-warm |

`uv run pytest` runs the engine's test suite. Full operational reference:
[`example-backend/README.md`](https://github.com/AmirAlsad/Conduit/blob/main/example-backend/README.md).
