# Conduit Connection Contract

This document describes how the **Conduit** iOS app connects to *your* voice
agent. It is meant to be handed to whoever runs the agent's backend. Conduit is a
thin audio pipe: it places a native phone call (CallKit) and carries real-time
audio over WebRTC. **The agent — model, voice, persona, memory — is entirely
yours.** There is no Conduit backend, no account, and no per-minute cost; Conduit
talks only to the endpoint you give it.

You connect an agent one of two ways. **Pairing** is the recommended path; **Direct
room** is the advanced fallback.

> For the reverse direction — your server **ringing the user** (agent-initiated
> inbound calls over a VoIP push) — see [INBOUND_CALLS](./INBOUND_CALLS.md).

---

## 1. Pairing endpoint (recommended)

The user pastes a **pairing endpoint URL** and an **API key** into Conduit. Before
each call, Conduit calls your endpoint, which mints a **fresh room + token** for
that single call and returns them. Short-lived per-call credentials are the whole
point: nothing in the app goes stale, and a leaked token is useless after the call.

### Request

```
POST <your pairing endpoint>
Content-Type: application/json
Authorization: Bearer <API key>      # the key the user entered; omitted if blank

{ "transport": "daily" }             # or "livekit"
```

- **Method:** always `POST`.
- **`Authorization`:** the user's API key as a bearer token. Sent only if the user
  provided a key; use it to authenticate the request however you like (validate it,
  rate-limit on it, ignore it for an open endpoint).
- **Body:** a JSON object with a single `transport` field — `"daily"` or
  `"livekit"` — telling you which WebRTC transport the user selected, so you can
  provision the matching room.
- **No agent identifier is sent.** *The endpoint identifies the agent* — one
  endpoint per agent (see [Multiple agents](#multiple-agents)). Conduit does not
  send an `agent_id`.

### Response

Return **HTTP 2xx** with a JSON body carrying the room URL and the access token.
Conduit accepts either of these shapes:

**Flat** (this is what a default Pipecat `/connect` server already returns) — Daily:

```json
{ "room_url": "https://your-domain.daily.co/abc123", "token": "<daily-meeting-token>" }
```

The **same shape** for LiveKit — the URL is your LiveKit server `wss://` URL and the
token is a LiveKit access token:

```json
{ "room_url": "wss://your-project.livekit.cloud", "token": "<livekit-access-token-jwt>" }
```

**Nested** under a `connection` object (accepted for either transport):

```json
{ "connection": { "room_url": "...", "token": "..." } }
```

Accepted keys, precisely:

| Field | Accepted keys | Required |
|---|---|---|
| Room URL | `room_url` (canonical) **or** `roomUrl` **or** `url` (fallback) | yes |
| Token | `token` | yes |
| Wrapper | top level **or** nested under `connection` | either works |

When several room-URL keys are present, `room_url` wins, then `roomUrl`, then `url`.

Per transport:
- **Daily:** `room_url` is the room URL (`https://<domain>.daily.co/<room>`); `token`
  is a Daily meeting token scoped to that room.
- **LiveKit:** `room_url` is your LiveKit **server** URL (`wss://<project>.livekit.cloud`),
  the same for every call; `token` is a LiveKit **access token** (a JWT) carrying a
  join grant for the specific room. LiveKit token servers commonly name the server
  URL `url` — Conduit reads that as a fallback, so a default LiveKit token-server
  response usually works unmodified. `room_url` stays the canonical key; a
  `serverUrl` key is **not** read — map that one.

### Errors

- **401 / 403** → Conduit shows the user "Authentication failed" (treat as a bad or
  missing API key).
- Any other non-2xx, an unreachable host, or a body missing `room_url`/`token` →
  Conduit shows a generic connection error and ends the call attempt.

### Minimal example server

A pairing endpoint is tiny. This FastAPI sketch mints a Daily room + token per
call (adapt the room/token minting to your provider):

```python
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

app = FastAPI()

class PairRequest(BaseModel):
    transport: str  # "daily" | "livekit"

@app.post("/connect")
async def connect(req: PairRequest, authorization: str | None = Header(default=None)):
    if authorization != f"Bearer {EXPECTED_API_KEY}":
        raise HTTPException(status_code=401)
    room_url, token = await mint_daily_room_and_token()   # your provider call
    # Start your agent/bot joining `room_url` here if it isn't already waiting.
    return {"room_url": room_url, "token": token}
```

> If you already run a **default Pipecat** server, its `/connect` route is likely
> compatible as-is: point Conduit's pairing endpoint at it.

For **LiveKit**, the endpoint mints an access token and ensures your agent is
dispatched to the room (the URL stays constant — the token scopes the room):

```python
from livekit import api  # livekit-server-sdk

@app.post("/connect")
async def connect(req: PairRequest, authorization: str | None = Header(default=None)):
    if authorization != f"Bearer {EXPECTED_API_KEY}":
        raise HTTPException(status_code=401)
    room = f"conduit-{uuid4().hex}"
    token = (api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
             .with_identity("caller")
             .with_grants(api.VideoGrants(room_join=True, room=room))
             .to_jwt())
    # Make sure your agent joins `room` (e.g. LiveKit Agents explicit dispatch).
    await dispatch_agent_to(room)
    return {"room_url": "wss://your-project.livekit.cloud", "token": token}
```

> **LiveKit: the agent must be a participant.** Conduit marks the call connected only
> once the room connects **and** a remote participant (your agent) is present — so
> dispatch/join the agent to that room when you mint the token. If no agent joins, the
> call sits at "connecting." (On Daily the same principle holds via the Pipecat bot.)

---

## 2. Direct room (advanced)

If you'd rather not run an endpoint, mint a room + token yourself and paste them
straight into Conduit:

- **Room URL** → the room (`https://<domain>.daily.co/<room>` for Daily;
  `wss://<project>.livekit.cloud` for LiveKit).
- **Token** → the room/access token. Optional if the room is open (no auth).

Conduit connects directly with these and makes no HTTP call. The trade-off is that
a token pasted here is fixed: when it expires, the user must edit the agent. Prefer
pairing for anything long-lived.

---

## Multiple agents

There is no `agent_id`; the **endpoint is the agent**. To offer several agents from
one backend, expose a different endpoint per agent and have the user add each as
its own agent in Conduit:

```
https://your-host/connect/jarvis      → mints a room for the Jarvis agent
https://your-host/connect/support     → mints a room for the support agent
```

Each endpoint provisions the room for *its* agent and returns the same response
shape above. The reference engine in
[`example-backend/`](https://github.com/AmirAlsad/Conduit/tree/main/example-backend)
ships exactly this: `POST /connect/{agent_id}` routes, with the bare `/connect`
defaulting to its `loopback` agent (see the [quickstart](backend/quickstart.md)).

---

## Call lifecycle: drops, hangups, and the end-call signal

Two events look identical from your side — the user's media vanishing — but they
need opposite responses:

- **A drop is not a hangup.** Conduit is built for cars and dead-zones: when media
  drops, the app reconnects with backoff **into the same room** while CallKit still
  shows the call as up. If your agent exits the moment the human leaves, the user
  reconnects into an empty room and the call dies. Hold the room for a grace window
  (the reference engine defaults to 60 s) and tear down only if nobody returns.
- **A real hangup says so explicitly.** When the user deliberately ends the call,
  Conduit sends an RTVI **`end-call` client message** before leaving, so you can
  tear down immediately instead of waiting out the grace window (your agent is a
  billed participant while it waits):

  ```json
  { "id": "<8 chars>", "label": "rtvi-ai", "type": "client-message", "data": { "t": "end-call" } }
  ```

  How it arrives depends on the transport. On **Daily** it comes through the
  Pipecat app-message channel — a Pipecat server sees it in the RTVI processor's
  `on_client_message` (with `message.type == "end-call"`). On **LiveKit** Conduit
  publishes the same envelope on the room's **data channel**; note that current
  Pipecat versions do *not* deliver client RTVI messages from LiveKit to the RTVI
  processor, so parse it from the transport's raw `on_data_received` event — see
  [`bot/runtime.py`](https://github.com/AmirAlsad/Conduit/blob/main/example-backend/bot/runtime.py)
  in the reference engine for a working implementation of both paths.

  The signal is best-effort: a connection that dies mid-drop never sends one, which
  is exactly when the grace window should apply.

---

## Notes for backend authors

- **Have the agent ready when you return credentials.** Conduit reports the call as
  "connected" only once media **and** the bot are live, so join the bot to the room
  as part of (or right after) handling the pairing request — don't make the user
  wait in an empty room.
- **Use HTTPS.** The API key travels as a bearer token. Conduit stores it only in
  the device Keychain and never logs it, but the endpoint must be HTTPS.
- **The `transport` field is authoritative for this call.** Provision the room for
  the transport Conduit asks for; don't assume one.
- **Keep credentials short-lived.** Per-call rooms/tokens are the design intent —
  scope them to a single call and a short TTL.
