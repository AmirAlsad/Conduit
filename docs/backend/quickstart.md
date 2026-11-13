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
openssl rand -hex 32     # paste the output as ENGINE_API_KEY in .env
```

`ENGINE_API_KEY` is required, and the engine refuses to start with it empty or
left at an example value. It is the only key this server has: the phone sends it
to pair, and it is also the admin key that rings the phone and can redirect its
rings (see [Before you expose it](#before-you-expose-it)).

Fill in the other keys only for what you run (`.env.example` annotates every variable):

| You want | You need |
|---|---|
| `loopback` over SmallWebRTC (zero cloud, LAN) | `ENGINE_API_KEY` only |
| `loopback` over Daily pairing | `ENGINE_API_KEY` + `DAILY_API_KEY` |
| Anything over LiveKit | + `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL` |
| The `live` agent | + `DEEPGRAM_API_KEY`, `GROQ_API_KEY`, `CARTESIA_API_KEY` |
| Direct mode (Daily/LiveKit) | a public URL + the SFU webhook ([details](direct-mode.md)) |

All transports run the **same pipelines with the same keys** — the transport only
changes how audio travels; the agent's STT/LLM/TTS keys are shared.

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

## 3b. Zero-cloud on your own Wi-Fi (SmallWebRTC)

The fastest zero-to-call path needs **no Daily or LiveKit account** — the engine
terminates WebRTC itself and your phone talks straight to your machine:

```bash
uv run uvicorn app.main:app --host 0.0.0.0     # 0.0.0.0 so the phone can reach it
uv run python scripts/pair.py --agent loopback --transport smallwebrtc \
    --base-url http://$(ipconfig getifaddr en0):8000
```

Scan the QR, allow the **local network** prompt iOS shows on first connect, and
call. Phone and laptop must share a network (the phone's hotspot counts); allow
incoming connections if macOS's firewall asks. Media is UDP peer-to-peer, so
this transport is for LAN / self-hosted-with-UDP setups — it won't work behind
an HTTP-only host like Railway.

## 4. Point the Conduit app at it

Deploy the engine to a public HTTPS host ([Deploy](deploy.md)), then the fast
path is a **QR code**:

```bash
uv run python scripts/pair.py --agent live --base-url https://your-host
```

Scan the printed QR with the iPhone Camera app — Conduit opens with the agent
pre-filled (name, transport, endpoint, key); just tap Save. Add `--inbound` to
also enable "Let this agent call me".

!!! warning "The link embeds your API key by default, and that key is the admin key"
    One scan = fully configured, but the link (and the QR) is then as secret as
    `ENGINE_API_KEY` itself, and in this reference server that key also rings the
    phone, ends calls, mints long-lived tokens and can redirect the agent's rings
    to another phone. Don't share or screenshot the QR. Pass `--no-key` to leave
    the key out and type it in the app instead.

Or fill **Add Agent → Connection** by hand:

- **Pairing endpoint** → `https://your-host/connect/live` (or any agent id)
- **API key** → your `ENGINE_API_KEY`
- **Transport** → Daily, LiveKit, or SmallWebRTC, matching the keys you configured

Tap **Test Connection** — it walks the stages (pairing endpoint → credentials →
transport → agent ready) and names the step that fails — then call.

## Before you expose it

The quickstart runs on your own machine. Before the engine is reachable from any
network you don't fully trust:

- **A real key.** `openssl rand -hex 32`; the engine refuses an empty or example one.
- **One key does everything here.** The key you give the phone is also the admin
  key (`/admin/ring`, `/admin/disconnect`, `/credentials`, overwriting
  `/inbound/register`). A production server should give the phone a separate,
  narrower key; this reference server does not.
- **HTTPS.** The key is a bearer token. Plain `http://` only on a LAN you trust.
- **Forwarded headers.** See [Deploy](deploy.md#forwarded-headers).

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/connect/{agent_id}` | bearer | Pairing: mint per-call creds, dispatch the agent now |
| POST | `/connect` | bearer | Same; agent from body or default (`loopback`) |
| POST | `/credentials/{agent_id}` | bearer | Direct: mint stable creds, dispatch later via webhook |
| POST | `/credentials` | bearer | Same; agent from body or default (`loopback`) |
| POST | `/webrtc/{agent_id}/offer` | bearer or offer token | SmallWebRTC: SDP offer in, answer out; spawns the agent in-process |
| PATCH | `/webrtc/{agent_id}/offer` | bearer or offer token | SmallWebRTC trickle-ICE candidates |
| POST | `/webhooks/daily`, `/webhooks/livekit` | signature | participant-joined → idempotent dispatch |
| POST | `/inbound/register/{agent_id}`, `/inbound/status/{agent_id}` | bearer | Push registration and ring receipts ([Inbound calls](inbound-calls.md)) |
| POST | `/admin/ring/{agent_id}` | bearer | Ring the registered phone |
| POST | `/admin/disconnect` | bearer | Force-end an agent in a room |
| GET | `/health` | none | Liveness / keep-warm |

`uv run pytest` runs the engine's test suite. Full operational reference:
[`example-backend/README.md`](https://github.com/AmirAlsad/Conduit/blob/main/example-backend/README.md).
