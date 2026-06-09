# iOS client ↔ Conduit engine — integration handoff

Everything the client team needs to connect to the deployed engine, run the
**M2 connect-and-downlink** gate, and satisfy the cross-team contracts. The
engine side (Daily **and** LiveKit, `loopback` **and** `live`) is validated
end-to-end against real Daily/LiveKit Cloud.

**Base URL:** `https://<your-deployed-engine-host>` (your own deployment — see
[deploy docs](../../docs/backend/deploy.md)).

> **Two values to share separately before forwarding** (kept out of the repo):
> - `ENGINE_API_KEY` — the bearer token (share over a secure channel, **not** in a ticket)
> - `HUMAN_ABSENT_GRACE_SECS` — the reconnection grace window (default **60** — see §5)

---

## 0. Run the M2 gate (the 60-second version)

1. Client POSTs `/connect` with the bearer + `{"agent_id":"live","transport":"daily"}`.
2. Read `connection.room_url` + `connection.token` from the response.
3. Join that Daily room **as an RTVI client** (see §2 — this is load-bearing).
4. On connect you should hear the agent **greet you** (immediate downlink audio),
   then be able to talk back-and-forth. That greet *is* the connect-and-downlink
   signal.

If the client is raw Daily media (no RTVI), the greet won't fire — the tester
must **speak** to get a downlink reply. See §2.

---

## 1. The `/connect` endpoint (pairing)

`/connect` creates a room, dispatches the agent into it **now**, and returns the
join credentials. The bot is already in the room when the call returns — join
before `expires_at`.

```bash
POST https://<your-deployed-engine-host>/connect/live
Authorization: Bearer {ENGINE_API_KEY}
Content-Type: application/json

{ "transport": "daily" }   # transport optional → agent/engine default; the URL names the agent
```

| field | values |
|---|---|
| `agent_id` | `"live"` (STT→LLM→TTS, greets on connect) · `"loopback"` (echo only; pipe/CallKit test) |
| `transport` | `"daily"` · `"livekit"` · omit → engine default |

### Response — note the nesting

`room_url`/`token` live under **`connection`**, not at the top level (this differs
from the vanilla Pipecat quickstart shape):

```jsonc
// Daily
{
  "transport": "daily",
  "connection": { "room_url": "https://<sub>.daily.co/<room>", "token": "<meeting-jwt>" },
  "agent_id": "live",
  "expires_at": "2026-06-08T01:31:35Z"   // ISO8601; gates the INITIAL connect only
}

// LiveKit  (transport: "livekit")
{
  "transport": "livekit",
  "connection": {
    "room_url": "wss://<project>.livekit.cloud",   // canonical (what the app reads)
    "url": "wss://<project>.livekit.cloud",        // deprecated alias
    "token": "<jwt>",
    "room_name": "conduit-<id>"
  },
  "agent_id": "live",
  "expires_at": "..."
}
```

Read `connection.room_url` + `connection.token` for both transports (LiveKit adds
`connection.room_name`, and the token scopes the room).

### Status codes

| code | meaning | client action |
|---|---|---|
| `200` | creds minted, bot dispatched | join the room |
| `401` | missing/invalid bearer | check `Authorization` header |
| `404` | unknown `agent_id` | fix the id |
| `503` | transport not configured, or the agent's model keys are missing on the engine | engine-side config issue — report it |

---

## 2. ⚠️ The client must be an RTVI client (the #1 integration point)

The `live` agent **greets on the RTVI `client-ready` event**, and the
listening/speaking glow + the end-call signal also ride RTVI. So if the client
connects as a **bare Daily/LiveKit media client**, three things silently don't
happen:

- **No auto-greet on connect.** The greet is gated on `client-ready`, which only
  an RTVI client emits. A raw media client hears downlink audio *only after the
  tester speaks*. For a connect-and-**downlink** gate this can read as a false
  failure.
- **No glow.** Speaking-state is delivered as RTVI messages; nothing consumes them.
- **Can't signal end-call.** It's an RTVI client message (§4).

**Recommendation:** layer a **Pipecat / RTVI client** over the Daily (or LiveKit)
transport, rather than driving the raw media SDK directly. That gives you
`client-ready` (→ greet), speaking-state callbacks (→ glow), and the client-message
channel (→ end-call) for free.

> If an RTVI client isn't ready for M2, two fallbacks: (a) the tester **speaks**
> to confirm downlink on a raw-media client, or (b) we move the greet to fire on
> transport-connect instead of `client-ready` — a small engine change. Tell us
> which you want.

---

## 3. The glow contract (RTVI speaking-state)

The client's listening/speaking glow is driven **entirely** by RTVI speaking-state
messages, which the engine emits automatically as the agent's TTS speaks (and from
VAD on the user side). An RTVI client surfaces these as callbacks — e.g.
bot-started-speaking / bot-stopped-speaking and the user-side equivalents. Bind the
glow to those. No engine change needed; just consume the events.

(`loopback` has no TTS, so it *synthesizes* the bot-speaking signal from inbound
audio energy — useful to exercise the glow on the bare pipe, but you'll normally
test the glow against `live`.)

---

## 4. Reconnection, the grace window, and end-call

This is the contract that makes a Conduit call survive a tunnel/dead-zone.

- **The bot does not exit when the human's media drops.** It holds the room for
  `HUMAN_ABSENT_GRACE_SECS`, so a reconnecting client resumes the *same*
  conversation (context intact). It tears down only if no human returns in the window.
- **Reconnect at the transport layer** — the Daily/LiveKit client SDK reconnects
  into the **same room**. Do **not** call `/connect` again to reconnect.
- **`expires_at` gates only the initial connect, never reconnects** — a short
  pairing token won't sabotage reconnection-with-backoff.
- **End-call signal.** To end *immediately* on a genuine hangup (vs a drop), send an
  RTVI client message:

  ```jsonc
  { "type": "end-call" }
  ```

  Without it, a real hangup just waits out the grace window — harmless, but the bot
  bills as a participant until the timer fires. So send `end-call` on
  user-initiated hangup.

---

## 5. Parameters we need to agree on

| # | question | why |
|---|---|---|
| 1 | **Your total reconnect-with-backoff budget (seconds)?** | We set `HUMAN_ABSENT_GRACE_SECS` ≥ this. Default 60. The bot bills during the window, so we don't want it longer than your budget. |
| 2 | **Is the M2 client RTVI-capable, or raw media?** | Determines whether the auto-greet fires (§2). |
| 3 | **Daily for M2, LiveKit later — confirmed?** | Both validated engine-side; response shape differs per §1. |
| 4 | **Bot identity** | The agent joins as participant name `Conduit Bot` (LiveKit identity prefix `bot-`). If you filter/subscribe by participant, that's how to tell the agent from the human. |

---

## 6. Later / optional

- **Direct mode (`POST /credentials`)** — stable, long-lived creds pasted into the
  app once; the bot is dispatched by an SFU **webhook** at join time rather than at
  provision time. Needs a one-time webhook registration on the engine and (today) a
  shared registry before it's redeploy-safe. Pairing (`/connect`) is simpler and is
  what M2 should use. See [`docs/direct-mode.md`](./direct-mode.md).
- **LiveKit transport** — same `/connect`, `transport: "livekit"`; payload shape per §1.

---

### Engine-side references (for the curious)

- Connect/credentials contract: [`app/models.py`](../app/models.py), [`app/routes/connect.py`](../app/routes/connect.py)
- Greet / end-call / RTVI wiring: [`bot/runtime.py`](../bot/runtime.py)
- Reconnection-safe teardown: [`bot/teardown.py`](../bot/teardown.py)
- Overview + the agent contract: [`README.md`](../README.md), [`docs/bring-your-own-agent.md`](./bring-your-own-agent.md)
