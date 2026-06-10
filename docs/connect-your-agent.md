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
- **The `transport` field is authoritative** — provision a Daily room, a LiveKit
  room+token, or a SmallWebRTC offer endpoint to match what the app asked for.
- The exact shapes, accepted key aliases, and error semantics are in the
  [connection contract](CONNECTION_CONTRACT.md). It also includes a minimal
  FastAPI pairing endpoint you can adapt — it's ~15 lines.

## Or scan a QR

Anything your server knows, a link can pre-fill. Conduit registers the
`conduit://` URL scheme:

```
conduit://add-agent?v=1&name=Live&transport=livekit
    &pair=<url-encoded pairing endpoint>[&key=…][&inbound=<url-encoded registration endpoint>]
```

Render that as a QR code and scanning it with the iPhone Camera opens a
pre-filled Add Agent sheet — the user just taps Save. Re-scanning a link whose
pairing endpoint matches an existing agent opens **Edit** instead of creating a
duplicate (handy after a key rotation), and a link without `key` never clears a
stored key. The example backend ships this as
[`scripts/pair.py`](backend/quickstart.md#4-point-the-conduit-app-at-it),
QR included.

!!! warning "A link with `key` is a secret"
    Treat a key-bearing link or QR exactly like the API key itself — share it
    over channels you'd trust with the key, or omit `key` and enter it in the
    app.

## SmallWebRTC — no cloud at all

The third transport drops the WebRTC cloud entirely: your server terminates the
peer connection itself (Pipecat's SmallWebRTC transport), so there's **no Daily
or LiveKit account** and nothing between your phone and your machine. Pairing
works exactly as above — the endpoint just returns an **offer URL** instead of a
room, and the app exchanges SDP with your server directly.

It's the fastest zero-to-call path for local development: run the
[example backend](backend/quickstart.md) on your laptop, scan a `pair.py` QR,
and you're talking to your agent over your own Wi-Fi. Two things to know:

- **Reachability:** media is UDP straight to your server — same network (or
  tailnet/VPN) required. It won't work behind an HTTP-only host like Railway,
  and crossing strict NATs needs STUN/TURN you'd configure yourself.
- iOS asks for **local network** permission on the first connection to a LAN
  address — a one-time prompt; the call connects once you allow it.

Wire details are in the [connection contract](CONNECTION_CONTRACT.md#smallwebrtc-offer-leg).

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
in CarPlay — by registering a push token and sending a VoIP push, with optional
**ring-status receipts** telling your server whether the ring was answered,
declined, or never seen (Focus/DND). That contract lives in
[Inbound calls](INBOUND_CALLS.md).
