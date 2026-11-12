# Conduit Inbound Calls (agent-initiated)

This document describes how *your* server makes **Conduit ring the user** — an
agent-initiated inbound call, delivered to the lock screen and CarPlay like any
phone call, then connected over the same WebRTC transport as an outgoing call. Hand
it to whoever runs the agent's backend. It is the inbound companion to
[CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) (outbound); read that first.

!!! tip "Reference implementation"
    The example backend implements all of this — token registration, the APNs
    sender, and a ring trigger. Operational guide:
    [Example backend → Inbound calls](backend/inbound-calls.md).

**Still no backend of ours.** Inbound needs a VoIP push, and Apple ties VoIP push to
the *app's* APNs key. Because Conduit is **self-built and self-signed** — you build
it under *your own* Apple Developer team — *you* hold the APNs key and *your* server
sends the push directly to Apple. The user's VoIP token only ever travels to your
own server. Anthropic/Conduit operates nothing at runtime.

---

## 0. One-time prerequisites (device)

- Build Conduit under **your own Apple Developer team** with the **Push
  Notifications** capability. The app already declares the `aps-environment`
  entitlement (`Conduit/Conduit.entitlements`) and the `voip` + `audio` background
  modes; you must enable Push Notifications on the App ID (a **paid** Apple Developer
  account).
- Create an **APNs auth key (`.p8`)** in your developer account and put it on your
  server. The VoIP push **topic** is `<your-bundle-id>.voip` (e.g.
  `com.yourname.Conduit.voip`).

Inbound is **opt-in per agent**: in Add Agent, toggle **"Let this agent call me"** and
give a **registration endpoint** (pre-filled from the pairing endpoint, editable).

---

## 1. Token registration

When the user enables inbound for an agent (and whenever iOS refreshes the token),
Conduit POSTs its device VoIP token to that agent's registration endpoint. Store it,
keyed to the user/agent, for use when you want to ring them.

### Request

```
POST <your registration endpoint>
Content-Type: application/json
Authorization: Bearer <API key>      # the agent's key; omitted if blank

{
  "voip_token": "<hex APNs VoIP token>",
  "platform": "ios",
  "bundle_id": "<the app's bundle id>",
  "agent_id": "<the agent's UUID in the app>",
  "display_name": "<optional>",          // the caller name the user gave the agent in the app
  "handle": "<optional>",                // the CallKit handle the app uses for it
  "push_features": ["cancel", "ring_timeout", "preconnect"]   // optional — see below
}
```

- `display_name` and `handle` are optional, sent by app builds from late 2026;
  omitted by older builds. Store them with the token and echo them in the ring push
  (§2). Only the app knows them — the user names agents locally — so don't invent
  your own.
- The app sends `display_name` cut to at most 120 characters (Unicode code points)
  and a `handle` well under 256; accept at least those lengths.
- `push_features` lists the optional push features the app's call engine supports
  (`CallEngine.supportedPushFeatures`): today `ring_timeout` (§2), `preconnect` (§5)
  and `cancel` (§5).
  Store it with the token and use a feature only with a registration that lists it.
  Keep names you don't know (later engines add more) and ignore them when ringing.
  Older builds omit the key: treat that as an empty list, so they get neither.

- The **VoIP token is per-install, app-wide** (not per-agent, not per-transport). The
  same token is registered with every agent the user opted in — each of your servers
  sees its own copy.
- Authenticate with the bearer key however you like (same key as the pairing
  endpoint). Return any 2xx.

### Unregistration (the user deleted the agent)

When the user deletes an inbound-enabled agent, Conduit sends a best-effort

```
DELETE <your registration endpoint>
Authorization: Bearer <API key>
```

Honor it by dropping the stored token and not ringing again. **Deletion is not
revocation**: only servers the user explicitly opted into ever hold the token, but
a server that ignores the DELETE (or never receives it — the request is
fire-and-forget) still holds a working token, and every push it sends will surface
a brief ring before the app ends it. The hard revocation is reinstalling the app —
that rotates the VoIP token, after which pushes to the old one get APNs
`410 Unregistered` — or revoking the APNs key itself.

---

## 2. Ringing the user

Send a **VoIP push** to APNs for the stored token.

```
POST https://api.push.apple.com/3/device/<voip_token>
apns-topic: <your-bundle-id>.voip
apns-push-type: voip
authorization: bearer <APNs JWT signed with your .p8>

{
  "agent_id": "<the agent's UUID>",     // required — which agent is calling
  "call_id":  "<a UUID you mint>",       // used as the CallKit call id
  "display_name": "<optional>",          // the caller name stored at registration
  "handle":   "<optional>",              // the CallKit handle stored at registration
  "room_url": "<optional>",              // inline credentials (see hybrid below)
  "token":    "<optional>",
  "status_url": "<optional>",            // ring-status receipts (see §4)
  "ring_timeout": "<optional>",          // whole seconds, as a string (see below)
  "preconnect": "<optional>"             // "credentials" | "media" (see §5)
}
```

All values are strings. `ring_timeout` and `preconnect` need a Conduit build on
call engine 0.2 or later; older builds ignore them, so a ring that carries them
still rings exactly as before. Send `ring_timeout` only when the registration's
`push_features` lists `ring_timeout`, and `preconnect` only when it lists
`preconnect` (§1). Without `ring_timeout` the phone rings for its own timeout, so
time anything you tie to the ring from that. Without `preconnect` the app will
not prepare, so a `media` agent you dispatched would sit in a room whose audio you
hold closed, waiting for a `call-answered` that never comes: ring such a device as
if you had not asked for pre-connect, and dispatch a plain agent.

**Ring timeout.** The app ends a ring nobody answers after its own timeout
(60 s by default) and reports `unanswered` (§4). `ring_timeout` shortens one
ring: the app clamps it to at least 10 s and to at most its own timeout, so it
can never lengthen a ring.

The app also accepts `target_id` in place of `agent_id` (if both are present,
`target_id` wins). `display_name` and `handle` are the values the app sent when it
registered its token (§1); include them whenever you stored them and omit the keys
otherwise. When they
are absent the app rings under a generic caller name and corrects it once it has
matched the `agent_id` locally.

### Credentials: hybrid (inline **or** pairing)

On answer, Conduit needs a room + token to join. You choose how it gets them:

- **Inline** — include `room_url` + `token` in the push. Conduit joins directly. Works
  for any agent (including direct-room agents). Use short-lived join tokens.
- **Via pairing** — omit `room_url`/`token`. After the user answers, Conduit resolves
  the agent's **pairing endpoint** exactly as for an outgoing call (see
  CONNECTION_CONTRACT). Nothing sensitive rides the push. Requires a pairing endpoint.

`room_url` is Daily's `https://…` room or LiveKit's `wss://…` URL, matching the
agent's transport — same shapes as the pairing response.

When a ring asks for `preconnect` (§5), the app may call the pairing endpoint
**while the phone is still ringing**, and then adds the ring to the usual body:

```
{ "transport": "<…>", "ring": { "call_id": "<the push's call_id>", "await_answer": true } }
```

`await_answer` is `true` when the app will also join the room before the user
answers (the `media` tier): the agent you dispatch must then stay silent until it
hears `call-answered` (§6). Without `ring` the request is an ordinary pairing call.

The ring may already be over when this request lands (the user declined, or you
canceled it, while the app was waking). Dispatch no agent for a ring whose first
receipt (§4) is anything but `answered`: refuse the request with a non-2xx. The
reference engine answers `409` with
`{"call_id": …, "status": "<the receipt, or canceled>", "reason": "ring ended"}`.
The app treats it as a failed preparation, which never ends a ring. A ring that
was `answered` first still gets its room and agent.

---

## 3. What the app does

1. **Push received** → Conduit reports an incoming call to CallKit **first**,
   synchronously inside the PushKit callback and before anything else, under the
   identity the push carries: `display_name`, else the generic name "Agent"; `handle`,
   else a handle derived from the id. Right after reporting it matches `agent_id` to a
   local agent and rings (`incomingRinging`). Once CallKit accepts the report, if the
   agent's name or handle differ from what rang, it updates the ring to show them.
   PushKit's completion is called after that, on every path. Credentials are used
   later (or during the ring, with `preconnect` — §5).
   A push it can't parse (no valid `agent_id`) is still reported, then ended at once.
2. **User answers** → Conduit connects the transport (inline creds, else pairing
   resolve), transitions to `connecting` → `connected`, and the call behaves exactly
   like an outgoing one (mute, routing, reconnection, interruptions).
3. **User declines** (or the call is never answered) → logged in Recents as a declined
   **incoming** call. On engine 0.2+ an unanswered ring ends after the ring timeout
   (§2, receipt `unanswered`), and a withdrawn ring ends on your cancel (§5, receipt
   `canceled`).
4. **Unknown `agent_id`** (not configured in the app) → Conduit still reports the call
   to satisfy PushKit, then ends it gracefully.
5. **Already on a call** → the new call is reported (corrected to the agent's identity
   if known), then ended at once and logged as a missed incoming call; the live call is
   untouched. A push arriving while a finished call's screen is still up rings normally.

---

## 4. Ring-status receipts (optional)

If you really needed to reach the user, "did the phone actually ring?" matters. Put a
`status_url` in the push payload and Conduit POSTs the ring's terminal status back to
it — fire-and-forget, authenticated like token registration (bearer = the agent's API
key, omitted if blank):

```
POST <status_url>
Content-Type: application/json
Authorization: Bearer <API key>

{ "call_id": "<the push's call_id>", "status": "<see below>" }
```

| `status` | Meaning |
|---|---|
| `answered` | The user answered (sent at answer, before the transport connects) |
| `declined` | The user declined the ring |
| `busy` | The push arrived during another Conduit call (logged as missed) |
| `suppressed_by_focus` | Focus/DND filtered the ring — the phone never rang (the call is still logged in the app's Recents as missed) |
| `unanswered` | The ring timed out with nobody answering (engine 0.2+) |
| `canceled` | You withdrew the ring before it was answered (§5; engine 0.2+) |

One receipt per ring, describing the *ring*: a normal hang-up after an answered call
sends nothing further. Omit `status_url` and the app sends nothing. Return any 2xx;
the app never retries.

If you dispatched an agent before the answer (inline credentials, §2), end it when
the ring's first receipt is anything other than `answered`: nobody is coming. Act on
the first receipt only, so a stray duplicate can't end an answered call. The
reference engine does this for every inline ring, pre-connected or not.

**Accept statuses you don't know.** Newer app builds may add statuses; answer them
with a 2xx like any other (a 4xx only loses the receipt). Treat any status other
than `answered` as "the ring is over and nobody picked up".

**Privacy note.** Receipts reveal the user's busy/Focus state to the server that rang
them. That server is the user's own (they opted into inbound for it), but if you're
adapting this contract, don't forward receipts anywhere else.

---

## 5. Pre-connect and canceling a ring (engine 0.2+)

### Pre-connect

`preconnect` in the ring push lets the app prepare while the phone rings, so the
call starts faster on answer:

| `preconnect` | During the ring | At answer |
|---|---|---|
| absent | nothing (as before) | fetch credentials, join |
| `"credentials"` | call the pairing endpoint with `ring` (§2) and keep the result | join with it |
| `"media"` | also join the room, with no audio either way | audio starts once iOS activates the call |

The app uses the lower of what you ask for, what it is configured to allow, and
what the agent's transport supports (not every transport can join during a ring:
Daily and SmallWebRTC stay at `credentials`), so you may see `credentials`
behaviour for a `media` ring. Anything missing means today's behaviour.

`"media"` is your promise that the agent holds its audio until the user answers.
Your agent must:

1. Produce no audio until it receives `call-answered` (§6).
2. End at once on `end-call`, as for any call. A decline, a timeout or a cancel
   while the phone is in the room all send it.
3. End by itself if no `call-answered` arrives within the ring timeout plus 15 s
   of being dispatched. Use the `ring_timeout` you sent; if the push carried none,
   the phone rings for the app's own configured timeout (60 s by default, but it
   can be longer or unlimited), which you can only assume. Send `ring_timeout`
   when you want a firm bound.
4. Use receipts as a fallback, not as the signal: wait for `call-answered`, and
   let `answered` release the greeting only if `call-answered` has not come 5 or
   more seconds after both the receipt and the device being in the room,
   whichever is later (a `call-answered` lost on the way). The app sends
   `answered` at the moment of answer, before its audio is up and often before it
   has (re)joined, and `call-answered` once it is, so a greeting released on the
   receipt itself plays into audio that is not up yet. The reference engine waits
   `ANSWERED_RECEIPT_GRACE_SECS` (default 5);
   `declined`, `unanswered`, `canceled`, `busy` or `suppressed_by_focus` mean end
   the agent. So send `status_url` with every pre-connected inline ring.

With `"credentials"` the app joins only after the answer, so the human joining
already means "answered"; the app still sends `call-answered`.

### Canceling a ring

To withdraw a ring that is still ringing:

- **In band (preferred).** If the ring is pre-connected (`media`) and the phone is
  in the room, make your agent leave the room. The app takes the agent leaving a
  ringing call as the cancel, ends the ring and reports `canceled`. No push, so
  nothing flashes.
- **Cancel push.** Otherwise, and only if the registration's `push_features`
  lists `cancel` (§1), send a second VoIP push:

  ```
  { "action": "cancel", "call_id": "<the ring's call_id>", "display_name": "<optional>" }
  ```

  Leave out `agent_id` and `target_id`. A 0.2 app ends the ring and reports
  `canceled` to the ring's `status_url`. An older app sees a push without a target
  and treats it as malformed: a brief flash of an incoming call, then ended, with
  no record and no receipt (iOS requires every VoIP push to show a call). Because
  of that flash, prefer the in-band cancel, and only push a cancel for a ring that
  has not ended yet. `action` absent or `"ring"` is a normal ring; any other value
  is treated as malformed.
- **Neither.** A registration without `cancel` can't take a cancel push, so don't
  send one: let the ring time out or be declined. The reference engine's cancel
  endpoint then refuses with `409` and `reason` `"cancel unsupported by device"`,
  and leaves the ring and its agent running.

A cancel push that arrives after the ring was answered changes nothing on the
phone, but an agent that leaves a room the user has already answered into ends the
live call, and on a pre-connected ring the room holds the phone both before and
after the answer. So an agent must not leave for a cancel once it has seen the
answer itself (`call-answered`, §6, or the human's audio), and must not act on a
cancel after the ring's `answered` receipt (§4). The `answered` receipt is sent at
the moment of answer, but `call-answered` only once audio is up, so the agent can
hold either one first. What stays racy is only the receipt's flight time: a cancel
that reaches the agent in the moment between the user answering and either signal
arriving cannot be told from one that came first. The reference engine's cancel
endpoint returns `409` for both (`reason` `"ring ended"` after a receipt,
`"ring answered"` when its ring bot saw the answer first) and leaves the bot alone.

---

## 6. Call-control messages to your agent (engine 0.2+)

Besides `end-call`, the app sends these RTVI client messages to the agent, in the
same envelope:

```json
{ "id": "<…>", "label": "rtvi-ai", "type": "client-message", "data": { "t": "call-answered" } }
```

| `t` | When |
|---|---|
| `call-answered` | The user answered a ring whose push carried `preconnect` (any value), once iOS has activated the call's audio and the transport is connected; sent again after every reconnect of that call |
| `call-held` | The call went on hold (e.g. the user took a cellular call) |
| `call-resumed` | The call came back from hold |

On hold the app's mic is off. A reasonable agent stops talking, takes no turns,
and gives a human who drops while held a longer grace window than a normal drop.

Delivery: on Daily (and SmallWebRTC) the messages reach Pipecat's RTVI processor
(`on_client_message`). On LiveKit they arrive as raw data packets: Pipecat's
LiveKit input does not route them to RTVI, so parse the envelope from the
transport's `on_data_received` event. The app sends no RTVI `client-ready` on
LiveKit, so greet on the first human join there instead.

Agents that don't know these messages can ignore them.

---

## Notes & caveats

- **Device + paid account only.** None of this runs in the iOS Simulator (no CallKit,
  no PushKit). Verify on hardware.
- **Privacy.** The VoIP token is not a secret credential, but treat it with care: a
  party holding both your APNs key and a device token can ring that device. Keys live
  on your server; tokens are sent only to servers the user opted into.
- **One call at a time.** Conduit handles a single call; a push that arrives
  mid-call is reported to the system and immediately ended (iOS requires every
  VoIP push to surface a call), landing in Recents as a missed incoming call —
  the active call is unaffected.
