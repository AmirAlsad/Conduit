# Conduit Engine

**Make your existing voice agent reachable as a native phone call.**

Conduit is a "dumb pipe" iOS calling app: it places a voice **agent** as a real
CallKit phone call, and the **agent owns the brain** (model, voice, persona,
memory). This repo is the *agent side* — the always-on service that hands the app
a room to join and runs your agent in it.

You already have a voice agent (or will build one). **This repo is not a tutorial
on building one** — it's the reference for **connecting yours to Conduit**: the
small contract your agent must satisfy, and a working engine that satisfies it.
`loopback` and `live` are reference agents you replace with your own; `tone` is
a test agent for on-device checks (a continuous tone from the moment the human
joins, no keys).

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

Over Daily and LiveKit your agent dials **out** to the cloud SFU, so those calls
need no inbound UDP, TURN or media termination. **SmallWebRTC** is the
exception: the engine terminates WebRTC itself (`/webrtc/{agent_id}/offer`,
always mounted, bearer or offer token), so its calls need UDP from the phone to
this machine; on an HTTP-only host they just fail to connect.

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

**3. Call it** — `POST /connect/myagent {"transport": "daily"}` (the URL names the
agent — this is the per-agent endpoint you paste into the Conduit app).

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
   the iOS client reconnects through tunnels/dead-zones. Stay for a grace window
   so a caller who comes back into the same room resumes the conversation, and
   end immediately only on an explicit hangup signal. `run_bot` + `bot/teardown.py` do
   this for you (`HUMAN_ABSENT_GRACE_SECS`; RTVI `{"type":"end-call"}` ends at once).
   See [Teardown](#teardown-reconnection-and-the-end-call-signal).

---

## The connection contract (what the app receives)

`/connect` and `/credentials` both return this shape (internal, not a frozen
public spec yet):

```jsonc
{
  "transport": "daily" | "livekit" | "smallwebrtc",
  "connection": {
    // daily:       { "room_url": "...", "token": "..." }
    // livekit:     { "room_url": "wss://...", "url": "wss://...", "token": "...", "room_name": "..." }
    //              (`room_url` is canonical — what the app reads; `url` is a deprecated alias)
    // smallwebrtc: { "room_url": "http(s)://<engine>/webrtc/<agent>/offer", "token": "<offer token>" }
    //              (pairing only)
  },
  "agent_id": "loopback" | "live" | "tone" | "<yours>",
  "expires_at": "<ISO8601 | null>"   // short for pairing, long/null for direct
}
```

Two ways the app gets here:
- **Pairing** (`POST /connect`) — engine creates a room, dispatches your agent into
  it *now*, returns short-lived creds. The agent is waiting as the app joins.
- **Direct** (`POST /credentials`) — engine returns stable, long-lived creds
  (pasted into the app once). At call time the app joins directly and an SFU
  **webhook** dispatches your agent. See **[docs/direct-mode.md](./docs/direct-mode.md)**.

Fastest app setup: `uv run python scripts/pair.py --agent live` prints a
`conduit://` pairing link + QR — scan it with the iPhone Camera and the app's
Add Agent sheet arrives pre-filled (the link embeds `ENGINE_API_KEY` unless
`--no-key`; treat it like the key).

Token lifetimes follow how the app reuses credentials. A pairing token matters
only until the phone joins: for an engine-level reconnect the app asks
`/connect` again (see [Teardown](#teardown-reconnection-and-the-end-call-signal)).
Direct credentials, and an inline ring's, are reused for every connection attempt,
reconnects included, so they must stay valid for as long as they are used: 30 days
for direct tokens (`DIRECT_TOKEN_TTL_SECS`), and for inline tokens
`PAIRING_ROOM_EXP_SECS` (1 h, the pairing room's own lifetime).

---

## Reference agents (examples to copy)

- **`loopback`** — echoes your audio back. No model, no keys, ~zero latency. It's
  the diagnostic for the *pipe* (CallKit↔WebRTC, route switching, mute, speaker
  default, raw quality) — if something's wrong here, it's the channel, not the
  agent. (`LOOPBACK_BOT_SPEAKING=false` for a pure passthrough.)
- **`live`** — a complete reference agent that satisfies all three contracts:
  `STT → LLM → TTS` (Deepgram · Groq · Cartesia by default), RTVI speaking-state,
  a greeting when the user is on the line (`call-connected`), barge-in,
  reconnection-safe teardown. **Copy this** as the
  starting point for your own. Swap any stage in `bot/pipelines/live.py`
  (TTS is also runtime-selectable via `TTS_PROVIDER`).
- **`tone`** — a test agent, not an example: a continuous 440 Hz tone from the moment
  a human joins, no keys, and it ignores client-ready, `call-connected` and hold. Ring
  it pre-connected (`scripts/ring.py --agent tone --inline --preconnect media`) to
  hear whether a ringing phone leaks any audio; see
  [Inbound calls](../docs/backend/inbound-calls.md).

---

## Quickstart (see the reference agent on a call)

```bash
uv sync
cp .env.example .env     # fill the keys you have; see .env.example for what each feature needs
openssl rand -hex 32     # paste the output as ENGINE_API_KEY in .env
```

The engine refuses to start with `ENGINE_API_KEY` empty or left at an example
value. Read [Security](#security-one-key-does-everything) before you expose it
to any network.

**Talk to an agent locally (no dispatcher):**
```bash
uv run python -m bot.bot                       # open http://localhost:7860/client
CONDUIT_AGENT=live uv run python -m bot.bot     # the live agent (default is loopback)
```

**The dispatcher + a pairing call:**
```bash
uv run uvicorn app.main:app --reload           # http://localhost:8000
curl -s -X POST http://localhost:8000/connect/loopback \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"transport":"daily"}'                   # ← the URL names the agent
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
| POST | `/connect/{agent_id}` | bearer | Pairing: create creds, dispatch the named agent now, return creds (a pre-connected ring's first request takes the room prepared at ring time instead) |
| POST | `/connect` | bearer | Same, body/default `agent_id` (defaults to `loopback`) |
| POST | `/credentials/{agent_id}` | bearer | Direct: create stable creds, register room, return creds |
| POST | `/credentials` | bearer | Same, body/default `agent_id` (defaults to `loopback`) |
| POST | `/webrtc/{agent_id}/offer` | bearer or offer token | SmallWebRTC: SDP offer → answer; spawns the agent **in-process** |
| PATCH | `/webrtc/{agent_id}/offer` | bearer or offer token | SmallWebRTC trickle-ICE candidates |
| POST | `/webhooks/daily` | signature | Daily participant.joined → idempotent dispatch |
| POST | `/webhooks/livekit` | signature | LiveKit participant_joined → idempotent dispatch |
| POST | `/inbound/register/{agent_id}` | bearer | The app registers its VoIP push token, plus (newer builds) the caller `display_name` and `handle`, the device's `push_features`, the `call_signals` its calls carry, and the `transport` its agent calls over (inbound calls) |
| DELETE | `/inbound/register/{agent_id}` | bearer | The app deleted the agent — drop its registration |
| POST | `/inbound/status/{agent_id}` | bearer | The app reports how a ring ended (answered / declined / busy / suppressed_by_focus / unanswered / canceled; unknown statuses are accepted). The first one releases or ends the ring's bot |
| POST | `/admin/ring/{agent_id}` | bearer | Ring the registered device — agent-initiated inbound call (push echoes the registered `display_name`/`handle`, when present; `ring_timeout`, sent only if the device lists that push feature, and then with every pre-connected ring (`RING_TIMEOUT_SECS` unless given); `preconnect` defaults to the best tier the device's registration takes). A ring whose agent starts before the push (inline, or a pre-connected pairing ring) is pushed once the agent's bot is in the room, at most `RING_BOT_WAIT_SECS` later |
| POST | `/admin/ring/{agent_id}/cancel` | bearer | Withdraw a ring still ringing: before its push (the engine is still waiting for the bot: the push never goes out), in band (the bot leaves a pre-connected room) or a cancel push (only if the device lists `cancel`). A ring bot is asked and refuses once it has seen the call answered. 404 unknown ring, 409 once it ended, once its bot saw the answer, or when the device can't take a cancel push |
| POST | `/admin/disconnect` | bearer | Force-end an agent in a room (drop test) |
| GET  | `/health` | none | Liveness / keep-warm |

Bearer = `Authorization: Bearer $ENGINE_API_KEY` (the dispatcher **refuses to
start if it's unset or an example value**; it is also the admin key, see
[Security](#security-one-key-does-everything)). Webhooks authenticate by signature (the caller is the SFU).
The `/webrtc/*/offer` routes also accept the short-lived **offer token** that a
smallwebrtc `/connect` minted, so the engine key never rides the offer leg.
Body for `/connect*` and `/credentials*`:
`{"transport": "daily"|"livekit"|"smallwebrtc"}`
(optional → agent/engine default; on the bare routes `agent_id` may ride in the
body, but a path `agent_id` always wins — **the endpoint identifies the agent**,
which is the shape the Conduit app expects: it POSTs `{"transport": ...,
"call_signals": [...]}` and no agent id).
Smallwebrtc is **pairing-only** (no `/credentials`), runs its bots as asyncio
tasks inside the dispatcher process, and needs the device to reach the engine
directly over UDP — LAN / self-hosted, not Railway.
Body for `/admin/disconnect`: `{"room_key": "<room>"}` (the room name from the
payload). `/admin/ring` rings via APNs VoIP push (`scripts/ring.py` wraps it;
needs the `APNS_*` vars) — full setup in the docs site's **Inbound calls** guide.
Body for `/admin/ring/{agent_id}` (all optional): `{"inline": bool, "transport":
…, "ring_timeout": <seconds>, "preconnect": "credentials"|"media"|"none",
"wait_for_bot": bool}`. `preconnect` omitted asks for the best tier the
device's registration takes (`media` with the `preconnect` push feature and the
`call-connected` call signal, `credentials` with the feature only, none without
it); `"none"` sends a plain ring. `"wait_for_bot": false` pushes at once (and a
pairing ring then prepares nothing). `transport` omitted uses the one the device
registered for its agent (`/inbound/register` body `"transport"`, sent by current
app builds); with none registered a pairing ring prepares nothing (the app's
request during the ring makes the room) and an inline ring uses the agent's
default. The response adds `bot_in_room` (whether the
ring's bot had joined its room when the push went out), `bot_wait_secs` (how
long the push waited); both are `null` when the ring did not wait; and
`transport`, that of the room made at ring time (`null` when none was made). For its
`/cancel`: `{"call_id": "<from the ring response>"}`. A `/connect` whose body
lists `"call-connected"` in `call_signals` dispatches a bot that waits for it
(`--await-connected`); one made during a pre-connected ring also carries
`"ring": {"call_id", "joins_before_answer"}`: the first such request for a ring
takes the room and **ring bot** the engine prepared at ring time; otherwise it
dispatches one (`--ring-deadline`, plus `--joins-before-answer` for media).

---

## Teardown, reconnection, and the end-call signal

The one place generic agent examples get it wrong for this client. The common
pattern cancels the pipeline the instant the human leaves — which **breaks**
Conduit's headline feature, since the iOS client drops media in tunnels/dead-zones
and reconnects with backoff while CallKit still shows the call up. So:

- On the human leaving, a **`HUMAN_ABSENT_GRACE_SECS`** timer starts; teardown only
  fires if no human rejoins. The agent stays, so the room is non-empty and a
  caller who comes back **into the same room** resumes the conversation.
- **Which reconnects come back to the same room.** The phone first lets the
  Daily/LiveKit SDK recover by itself, for up to 30 s, in the same room. If that
  fails it reconnects itself, with attempts after 1, 2, 4, 8, 16 and 30 s (plus
  each attempt's connect time). Those attempts reuse direct and inline
  credentials, so they rejoin the same room; for a **pairing** agent each one
  asks `/connect` again, and this engine answers as it does for any call: a
  **new room and a new bot, which greets again** with no memory of the call,
  while the old bot waits out its grace window alone. Handing a reconnecting
  phone its old room is not built. SmallWebRTC has no SDK recovery: a dropped
  peer ends its bot at once, and the phone's next offer starts a new one.
- An **explicit end signal** ends a real hangup at once: the client sends the RTVI
  client message `end-call`, or you hit `POST /admin/disconnect`. Without it, every
  hangup harmlessly waits out the window (as a billed participant). On Daily the
  signal arrives through the RTVI processor (`on_client_message`); on LiveKit,
  Pipecat's input path doesn't deliver client RTVI messages, so the engine parses
  the same message from the raw `on_data_received` event (`bot/runtime.py`). The
  Conduit app sends it on every deliberate hangup, on both transports.

> **`HUMAN_ABSENT_GRACE_SECS`** (default `120`) must cover the phone's reconnect
> budget for the calls that come back to the same room: Conduit's is about 100 s
> (30 s of SDK recovery, then attempts after 1, 2, 4, 8, 16 and 30 s, plus connect
> time). Your agent is a billed participant during the window, and a pairing
> call's old bot waits it out in full after a stage-2 reconnect.

### Call-control signals: when to speak, and hold

The app also sends `call-connected` client messages (same RTVI envelope as
`end-call`; same per-transport delivery). The entrypoint handles them for you
(`bot/call_control.py`), and also `call-held` and `call-resumed`, which Conduit
does not send (its calls cannot be held: a phone call ends the call) but an app
on the call engine with its experimental hold turned on does:

- **Speak on `call-connected`.** The app sends it on every call once the user is
  on the line: the call is connected, iOS has activated its audio, it is not held,
  and the app's own "Connected" has played. An app says it sends it by listing it
  in `call_signals` (in the `/connect` body, and in its `/inbound/register` body
  for rings whose bot starts before the app asks for anything). Such a bot
  (`--await-connected`, on Daily, LiveKit and SmallWebRTC alike, for outgoing
  calls and rings) keeps the pipeline's audio gates closed and doesn't greet until
  it arrives; a repeat after a reconnect greets no one again. An app that lists
  nothing is greeted when it is ready, exactly as before. As a fallback for a lost
  `call-connected`, the bot greets anyway `CALL_CONNECTED_GRACE_SECS` after it
  knows the user answered and the device is in the room, whichever is later. For
  a ring, the answer is `call-connected`, the ring's `answered` receipt (sent at
  the moment of answer, before the app's audio is up, so it only starts that
  wait), or the device joining a ring it joins only after the answer; the device
  leaving stops the wait and its return restarts it. With `--ring-deadline` the
  bot ends if no answer comes in time. A `"media"` ring (`--joins-before-answer`)
  stays silent until then even for an app that lists nothing, and is only sent to
  an app that lists `call-connected`.
- **Hold** (from an app that holds calls; not Conduit). `call-held` interrupts the bot and closes its audio gates (no turns,
  no speech) until `call-resumed`; a human who drops while held gets
  `HELD_GRACE_SECS` instead of `HUMAN_ABSENT_GRACE_SECS`. The app sends it as soon
  as it is in the room, also while the call still shows connecting, so a hold
  stops the `call-connected` fallback wait: nothing is released or greeted while
  held. `call-resumed` starts that wait again in full, and greets at once a bot
  already on the line that has not greeted yet.
- **Greeting.** `on_ready` runs on `call-connected` for an awaiting bot, once;
  otherwise on RTVI client-ready (Daily, SmallWebRTC) and on the first human join
  on LiveKit, whose app sends no client-ready (and whose client messages never
  reach Pipecat's RTVI processor).

For your own pipeline to honour `call-connected` and hold, put an
`AudioGate` after `transport.input()` and one before `transport.output()`, and
return them as `BotBuild(gates=…)` — see `bot/pipelines/live.py`.

## Tuning knobs (for the reference `live` agent)

- **`VAD_STOP_SECS`** (default `0.2`) — endpointing delay. Turn-end uses Pipecat's
  default **Smart Turn v3** (auto-applied; you'll see it load at startup). Raise this
  to give a thinking-partner more silence tolerance, at some latency cost.
- **`TTS_PROVIDER`** — `cartesia` (default) | `deepgram` | `groq`; each reuses that
  provider's key. The agent's required-keys check follows it.
- **`HUMAN_ABSENT_GRACE_SECS`** (default `120`) — see above. **`HELD_GRACE_SECS`** (default `600`)
  replaces it while the call is on hold.
- **`HUMAN_JOIN_TIMEOUT_SECS`** (default `45`, `0` turns it off) — a bot whose
  room has had no human this long after it started ends itself, rather than
  billing until `PIPELINE_IDLE_TIMEOUT_SECS` (30 min): the user hung up while
  pairing was in flight, the phone abandoned a prepared room, a direct-mode
  caller left before the bot arrived. Conduit gives up joining after 30 s. Any
  sign of the device (a join, RTVI client-ready, `call-connected`, or the
  transport listing someone in the room) cancels it for good; a device that
  leaves later gets the grace window instead. A ring bot counts it from the
  answer (its ring deadline governs before that); a plain inline ring's bot,
  which the phone joins only after the answer, waits the ring's whole deadline.
- **`RING_BOT_WAIT_SECS`** (default `8`, `0` turns it off) — agent-first ringing:
  a ring whose agent starts before the push (inline, or a pre-connected pairing
  ring) is pushed once the agent's bot has joined the room, or after this many
  seconds without it, so a slow or broken bot never blocks a ring. A ring bot's
  deadline grows by the same amount, so the wait never shortens the ring.
- **`PREPARED_CLAIM_GRACE_SECS`** (default `10`) — a pre-connected pairing ring
  answered before the phone took its prepared room keeps that room and its agent
  this long for the phone's credential request, which may still be on the way
  (the `answered` receipt is sent at the answer). A request in that time takes
  the room; after it, the agent is ended and a late request gets a fresh room.
- **`RING_TIMEOUT_SECS`** (default `60`, must be > 0) and
  **`RING_DEADLINE_MARGIN_SECS`** (default `15`) — a ring bot ends when the ring's
  timeout plus the margin passes without an answer. A pre-connected ring to a
  device that lists the `ring_timeout` push feature always carries one, as the
  push contract asks: the request's, else `RING_TIMEOUT_SECS`. For a device that
  doesn't list it, `RING_TIMEOUT_SECS` is the ring length *assumed*: the phone
  rings for its own configured timeout (60 s by default, but the app can make it
  longer or unlimited), so match it to your app's.
- **`CALL_CONNECTED_GRACE_SECS`** (default `10`, must be >= 5, the push
  contract's floor) — how long an awaiting bot waits for a `call-connected` that
  may have been lost, counted from the later of knowing the user answered and the
  device being in the room, before it greets anyway. Keep it above the app's own
  sequence after it joins (Conduit's minimum connecting time, about 2.6 s, and its
  "Connected", which the engine bounds at 5 s). It replaces
  `ANSWERED_RECEIPT_GRACE_SECS`, which is no longer read.

See `.env.example` for the full list and which feature needs which key.

---

## Deploy (your own way)

A single always-on web process; its inbound surface is HTTPS, plus UDP for
SmallWebRTC calls where the host lets UDP in. Keep it a **single
process** (see caveats) and **always-on** (no app-sleeping — it must answer
webhooks and `/connect` without a cold start).

- **Docker / any host**: a [`Dockerfile`](./Dockerfile) is provided (Python 3.12 +
  uv, `uv sync --frozen`, binds `${PORT:-8000}`). `docker build -t conduit . &&
  docker run -p 8000:8000 --env-file .env conduit`. `.dockerignore` keeps
  `.venv`/`.env`/`node_modules` out — inject secrets via your platform, never the image.
- **Railway**: `railway.json` sets the start command + `/health` check. **Disable
  Serverless / App Sleeping.**
- **Forwarded headers.** Ring pushes carry a `status_url` built from the request's
  scheme and host, so behind a TLS proxy uvicorn runs with `--proxy-headers`. The
  Dockerfile trusts forwarded headers only from `FORWARDED_ALLOW_IPS` (uvicorn's
  default `127.0.0.1`): set it to your proxy's address. `railway.json` and the
  `Procfile` trust any address (`--forwarded-allow-ips="*"`), which is right only
  because Railway's edge is the sole way in; don't copy that to a host whose port
  anyone can reach.

Then set the env vars on the platform, and **for direct mode only** register the
SFU webhook **once** against your public URL (persists across redeploys):
```bash
uv run python scripts/daily_webhook.py register --base-url https://<your-public-host>
# LiveKit: register https://<your-public-host>/webhooks/livekit in the LiveKit
# Cloud dashboard (Settings → Webhooks) — there's no API for it.
```
Provision the credentials to paste into the app with
`uv run python scripts/provision.py --transport daily|livekit`.
Full deploy + webhook details: **[docs/direct-mode.md](./docs/direct-mode.md)**.

---

## Security: one key does everything

This is a reference server, and it keeps auth deliberately simple: **one
`ENGINE_API_KEY` is both the key the phone uses and the admin key.** Whoever
holds it can:

- start billable agents (`/connect`) and mint long-lived room tokens (`/credentials`);
- ring the registered phone (`/admin/ring`) and end any agent (`/admin/disconnect`);
- overwrite an agent's push registration (`/inbound/register`), which redirects
  that agent's rings to another phone, and post ring receipts (`/inbound/status`).

The phone stores the key in its Keychain and sends it with every pairing request,
registration and receipt. `scripts/pair.py` embeds it in the `conduit://` link and
QR code by default (`--no-key` leaves it out), so **treat that QR like the key**:
don't screenshot it into a chat or leave it on a shared screen. If it leaks,
generate a new key, restart the engine, and re-enter it in the app.

Before you expose this server to a network:

- Generate the key with `openssl rand -hex 32`; the engine refuses an empty or
  example key.
- Serve it over HTTPS (the key is a bearer token). Plain `http://` is only for a
  LAN you trust (SmallWebRTC testing).
- Decide whether one key is acceptable for you. A production server should give
  the phone a separate key that can only pair, register and post receipts, and
  keep the admin routes (`/admin/*`, `/credentials`) behind a key the phone never
  sees. This server does not do that yet.
- Check the forwarded-header trust of your start command (see
  [Deploy](#deploy-your-own-way)).

---

## ⚠️ Operational caveats

- **The registry is durable only if its file is.** Direct-mode rooms and inbound
  VoIP tokens live in a SQLite file (`REGISTRY_DB_PATH`, default `registry.db`).
  On an ephemeral filesystem a redeploy wipes it: direct-mode webhooks find no
  room, so no agent is dispatched and the app ends the call after 30 s as "Agent
  didn't join", until you re-provision; and inbound ringing fails until the app
  registers its token again (on save, or when PushKit next hands it the token,
  usually at launch). Mount a volume (e.g.
  `/data/registry.db` on Railway) to survive redeploys. (Pairing is unaffected.)
- **Single dispatcher process only.** Idempotency uses per-room asyncio locks +
  process-local active-bot state, which serialize only within one event loop —
  SQLite does not make replicas safe. Don't run replicas or `--workers > 1`.
- **Daily webhooks** need a credit card on the Daily account and fire domain-wide;
  the engine filters to registered rooms and ignores the agent's own join.
- **No Pipecat JS LiveKit client** yet — the web test client drives **Daily only**.
  Use `meet.livekit.io` / the LiveKit Agents Playground, or the iOS app, for LiveKit.
- **Redeploys kill in-flight agents** and drop active calls — deploy when quiet.

## Design & scope

**Out of scope (fast-follows):** TURN for smallwebrtc across NATs, native
`livekit-agents` token-encoded dispatch, freezing the public connection spec.
