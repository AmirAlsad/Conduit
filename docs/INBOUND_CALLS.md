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
Turning it on also asks for the microphone, so that a call answered from the lock
screen can carry the user's voice.

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
  "push_features": ["cancel", "ring_timeout", "preconnect"],  // optional — see below
  "call_signals": ["call-connected", "call-held", "call-resumed"]   // optional — see below
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
- `call_signals` lists the call-control messages the app's calls carry (§6), the
  same list it sends with every pairing request. An agent you start for a ring
  before the app asks for credentials (inline credentials, §2) waits for
  `call-connected` before it greets only if the registration lists it. Send
  `preconnect: "media"` only to a registration that lists `call-connected` (§5).

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
`preconnect` (§1), and `"media"` only when it also lists the `call-connected` call
signal. Without `ring_timeout` the phone rings for its own timeout, so time
anything you tie to the ring from that. Without `preconnect` the app will not
prepare: ring such a device as if you had not asked for pre-connect, and dispatch a
plain agent.

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
{ "transport": "<…>", "call_signals": [ … ],
  "ring": { "call_id": "<the push's call_id>", "joins_before_answer": true } }
```

`joins_before_answer` is `true` when the app will also join the room before the
user answers (the `media` tier): the device joining is then not the answer, and the
agent you dispatch must stay silent until it hears `call-connected` (§6). Without
`ring` the request is an ordinary pairing call.

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
3. **User declines** → logged in Recents as a declined **incoming** call (receipt
   `declined`). A ring nobody answers or declines is logged as a **missed** call: on
   engine 0.2+ it ends after the ring timeout (§2, receipt `unanswered`), or when
   you withdraw it (§5, receipt `canceled`), and the app posts a quiet local
   notification. A ring that was busy or Focus-filtered is missed too (§4).
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

`call_id` is the ring's UUID in lowercase; the one in your push may be spelled
differently, so **compare it case-insensitively** (parse both as UUIDs, or lowercase
both). Builds on engine 0.1 sent it in uppercase.

One receipt per ring, describing the *ring*: a normal hang-up after an answered call
sends nothing further. Omit `status_url` and the app sends nothing. Return any 2xx;
the app never retries.

If you dispatched an agent before the answer (inline credentials, §2, or a room you
prepared for a pre-connected pairing ring, §5), end it when the ring's first receipt
is anything other than `answered`: nobody is coming. Act on the first receipt only,
so a stray duplicate can't end an answered call. The reference engine does this for
every inline ring, pre-connected or not, and for every pairing ring it prepared at
ring time; it also ends a prepared agent at `answered` when the app never asked for
that room (an app that did not prepare connects with a request of its own).

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
LiveKit and Daily do, Daily with the agent's audio unsubscribed until the answer;
SmallWebRTC stays at `credentials`), so you may see `credentials` behaviour for a
`media` ring. Anything missing means today's behaviour.

`"media"` is your promise that the agent holds its audio until the user answers.
Your agent must:

1. Produce no audio until it receives `call-connected` (§6).
2. End at once on `end-call`, as for any call. A decline, a timeout or a cancel
   while the phone is in the room all send it.
3. End by itself if no `call-connected` arrives within the ring timeout plus 15 s
   of the push (an agent started before the push, as the reference engine's are,
   adds the time the push was held for it; the reference engine adds its whole
   `RING_BOT_WAIT_SECS` bound). Use the `ring_timeout` you sent; if the push carried none,
   the phone rings for the app's own configured timeout (60 s by default, but it
   can be longer or unlimited), which you can only assume. Send `ring_timeout`
   when you want a firm bound.
4. Use receipts as a fallback, not as the signal: wait for `call-connected`, and
   let `answered` release the greeting only if `call-connected` has not come 5 or
   more seconds (10 is safer) after both the receipt and the device being in the
   room, whichever is later (a `call-connected` lost on the way). The app sends
   `answered` at the moment of answer, before its audio is up and often before it
   has (re)joined, and `call-connected` once the user is on the line, so a
   greeting released on the receipt itself plays into audio that is not up yet.
   The reference engine waits `CALL_CONNECTED_GRACE_SECS` (default 10);
   `declined`, `unanswered`, `canceled`, `busy` or `suppressed_by_focus` mean end
   the agent. So send `status_url` with every pre-connected inline ring.

With `"credentials"` the app joins only after the answer, so the human joining
already means "answered"; as on every call, greet on `call-connected` (§6).

### Ready when the user picks up

The phone joins a `media` ring's room within a fraction of a second of the push;
what the user waits for is your agent. In one Daily `media` ring with inline
credentials the phone was in the room 0.3 s after the push, the user answered at
2 s, and the agent joined at 6.7 s (2 to 5 s in other rings that day), so the
answered call sat connecting for 4.6 s. So:

- **Start your agent first, and send the push once it is in the room**, bounding
  that wait to a few seconds so a slow agent never holds the ring back. At the very
  least start it when you send the push, not when the phone asks for credentials
  after the answer.
- **Ask for pre-connect on every ring** to a device that lists `preconnect` in its
  `push_features`: `"media"` when it also lists `call-connected` in `call_signals`
  (and your agent waits for it), `"credentials"` otherwise. A device that lists
  neither gets a plain ring, which works as before.
- **Without inline credentials, return the room your agent is already in** to the
  pairing request the app makes during the ring: it carries the ring's `call_id`
  (`ring.call_id`, §2).

The reference engine does all three by default (see the backend guide,
`docs/backend/inbound-calls.md`); the room it prepares at ring time for a pairing
ring uses the ring's transport (`--transport`, or the agent's default), and a
request for another transport gets a fresh room. What the user experiences:

| Case | What the user experiences |
|---|---|
| Ready at the answer (`media`, the agent in the room before the answer) | Connected the moment they pick up; nothing from the app is said; iOS activates the audio a fraction of a second later, `call-connected` reaches the agent then, and it greets. |
| Answered before the agent was there (`media`, agent still starting) | Connecting from the answer, with no ringback; if still connecting a second after the answer, "Connecting" once; connected the moment the agent is in the room, then "Connected", then `call-connected`. No minimum connecting time applies to an answered call. |
| Credentials only during the ring (`credentials`, or `media` lowered to it, e.g. SmallWebRTC) | The phone joins at the answer: connecting for the join plus the agent's readiness, with the same sounds as the row above; short if the agent is already in the room. |
| Pre-connect failed (credentials refused, room unreachable, a drop, the agent not in the room within 30 s of the phone's join, or the agent leaving before it was there) | During the ring, nothing changes: it keeps ringing, and an answer connects as without pre-connect (an ordinary pairing request, no `ring`). After the answer, the call stays connecting and makes that ordinary request once. |

An agent that never arrives fails the call: 30 s after the phone's join (the
app's join timeout), then, for an answered pre-connected ring, once more after the
ordinary request, the call ends as "Agent didn't join".

### Canceling a ring

To withdraw a ring that is still ringing:

- **Before the push.** A server that starts its agent first (§5, "Ready when the
  user picks up") may be asked to cancel while it is still waiting for that agent:
  send no push, and end the agent. The reference engine answers such a cancel with
  `"method": "before_push"`.
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
answer itself (`call-connected`, §6, or the human's audio), and must not act on a
cancel after the ring's `answered` receipt (§4). The `answered` receipt is sent at
the moment of answer, but `call-connected` only once audio is up, so the agent can
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
{ "id": "<…>", "label": "rtvi-ai", "type": "client-message", "data": { "t": "call-connected" } }
```

| `t` | When |
|---|---|
| `call-connected` | The user is on the line: on every call (placed by the user, or a ring answered, prepared or not), once the call is connected, iOS has activated its audio, it is not held, and the app's own "Connected" has finished; sent again after every reconnect |
| `call-held` | The call went on hold: the user took or placed a cellular call, or pressed Hold in the app. Any call, incoming or outgoing; sent as soon as the app is in the room, also while the call still shows connecting (so it can come before `call-connected`); sent again after every reconnect of a held call |
| `call-resumed` | The call came back from hold |

**When your agent should start speaking: on `call-connected`, not when the
session connects.** The app lists the messages it sends as `call_signals` in every
pairing request and in its token registration (§1). An agent started for a request
or registration that lists `call-connected` keeps quiet until it arrives, then
greets, once: a repeat after a reconnect is the same call. Before it, the device can
already be in the room: during its ringback on a call the user placed (the app
shows "connecting" for at least about 2.6 s, so the first ring tone always plays in
full), while an answered call is still connecting, and, for a `media` ring, while
the phone still rings. A call answered with its agent already there says nothing
of its own, so `call-connected` follows the answer within about a second. Being muted or in push-to-talk does not delay it:
the user hears you. Treat it with `call-held` and `call-resumed` as state: the user
is on the line once you have had `call-connected`, and away while the latest of the
three is `call-held` (`call-connected` is never sent while the call is held; a call
that connects during a hold gets `call-resumed` and then `call-connected` at the
resume). An agent started for a request or registration that does not list it (an
older app, a third-party client, a direct room) greets when the client is ready, as
before. **Fallback:** a listed `call-connected` can be lost, so once your agent
knows the user answered (at once for an ordinary call; for a ring, its `answered`
receipt, or the device joining a ring it joins only after the answer) and the device
is in the room, it greets anyway if `call-connected` has not come within a grace
period: 5 seconds at least, 10 to cover the app's own sequence after it joins (on a
call the user placed, the minimum connecting time; and its "Connected", which the
app bounds at 5 s). The fallback must not fire while the call is held: the app
sends `call-held` as soon as it is in the room, also while the call still shows
connecting, so stop the wait on `call-held`, start it again in full on
`call-resumed`, and greet at the resume if your agent is on the line but has not
greeted. A greeting during a hold plays to nobody (or is dropped by your own audio
gate while staying in the conversation as if it had been said). The
reference engine does all of this (`CALL_CONNECTED_GRACE_SECS`, default 10).

On hold the app's mic is off and, where the transport can, its playout too. A
reasonable agent stops talking, takes no turns, and gives a human who drops while
held a longer grace window than a normal drop. SmallWebRTC's SDK cannot stop
playout, so on that transport a held call is silent only if the agent honours
`call-held`.

Each message is sent once the connection to the agent is up, and the app learns
whether it left the device: if it did not, it sends the call's current state
again after 1, 2, 4, 8, 16 and 30 seconds, so a lost `call-held` does not leave
the agent talking, and a lost `call-resumed` does not leave it silent. Expect
the same message more than once, and treat each as the call's current state
rather than an event to count.

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
