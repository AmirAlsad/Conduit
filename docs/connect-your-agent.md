# Connect your agent

Conduit is a thin audio pipe: it places the call, your backend supplies the agent.
Connecting the two means answering one question — **how does the app get a room
and a token for each call?** There are two answers.

## Pairing (recommended)

You give Conduit a **pairing endpoint URL** and an **API key** (Add Agent → Connection).
Before each call, the app POSTs that endpoint; your server mints a **fresh room +
token** for that one call, makes sure your agent joins the room, and returns the
credentials. Nothing in the app ever goes stale, and a leaked token is useless
minutes later.

```
Conduit ── POST {"transport": "daily"|"livekit"} + Bearer <API key> ──► your endpoint
        ◄─────────── { "room_url": "...", "token": "..." } ───────────┘
Conduit joins the room; your agent is already there.
```

- **The endpoint identifies the agent.** Conduit never sends an agent id — to
  offer several agents, expose one endpoint per agent (`/connect/jarvis`,
  `/connect/support`) and add each as its own agent in the app.
- **The `transport` field is authoritative** — provision a Daily room or a LiveKit
  room+token to match what the app asked for.
- The exact shapes, accepted key aliases, and error semantics are in the
  [connection contract](CONNECTION_CONTRACT.md). It also includes a minimal
  FastAPI pairing endpoint you can adapt — it's ~15 lines.

## Direct room (advanced)

No endpoint: mint a long-lived room + token yourself and paste them into
Add Agent → **Direct room (advanced)**. The app joins them directly with no HTTP
call. The trade-off is staleness — when the pasted token expires you must edit the
agent — and your backend needs a way to know when to join its agent to the room
(the [example backend](backend/direct-mode.md) uses the SFU's participant-joined
webhook for that). Prefer pairing for anything long-lived.

## Don't have a backend yet?

Use the **[example backend](backend/quickstart.md)** — a self-contained
FastAPI + Pipecat service you run under your own API keys. Out of the box it
serves both transports and both connection modes, ships a zero-keys echo agent
(`loopback`) and a full STT→LLM→TTS reference agent (`live`), and its per-agent
pairing endpoints are exactly what the app's pairing field expects:

```
https://your-host/connect/live      ← paste this as the pairing endpoint
```

When you outgrow the reference agents, you write one pipeline-factory function
and keep everything else — see
[Bring your own pipeline](backend/bring-your-own-pipeline.md).

## The reverse direction

Your agent's server can ring **you** — a real incoming call on the lock screen and
in CarPlay — by registering a push token and sending a VoIP push. That contract
lives in [Inbound calls](INBOUND_CALLS.md).
