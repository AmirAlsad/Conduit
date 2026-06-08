# Conduit Connection Contract

This document describes how the **Conduit** iOS app connects to *your* voice
agent. It is meant to be handed to whoever runs the agent's backend. Conduit is a
thin audio pipe: it places a native phone call (CallKit) and carries real-time
audio over WebRTC. **The agent — model, voice, persona, memory — is entirely
yours.** There is no Conduit backend, no account, and no per-minute cost; Conduit
talks only to the endpoint you give it.

You connect an agent one of two ways. **Pairing** is the recommended path; **Direct
room** is the advanced fallback.

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

**Flat** (this is what a default Pipecat `/connect` server already returns):

```json
{ "room_url": "https://your-domain.daily.co/abc123", "token": "eyJhbGci..." }
```

**Nested** under a `connection` object:

```json
{ "connection": { "room_url": "https://your-domain.daily.co/abc123", "token": "eyJhbGci..." } }
```

Accepted keys, precisely:

| Field | Accepted keys | Required |
|---|---|---|
| Room URL | `room_url` **or** `roomUrl` | yes |
| Token | `token` | yes |
| Wrapper | top level **or** nested under `connection` | either works |

For **Daily**, `room_url` is the room URL (`https://<domain>.daily.co/<room>`) and
`token` is a Daily meeting token. For **LiveKit**, put the LiveKit server URL
(`wss://<project>.livekit.cloud`) under `room_url`/`roomUrl` and the participant
access token under `token`. If your token server returns the URL under a different
key (e.g. LiveKit's `serverUrl`), map it to `room_url`/`roomUrl` in the response.

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
shape above.

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
