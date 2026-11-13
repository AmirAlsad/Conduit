# Inbound calls (your agent rings you)

The engine can make Conduit **ring the user's iPhone** — a real lock-screen /
CarPlay incoming call, agent-initiated. This page is the operational guide for the
reference engine; the app↔server contract it implements is
[Inbound calls (contract)](../INBOUND_CALLS.md).

How it fits together:

1. The user enables **"Let this agent call me"** in the app → the app registers its
   VoIP push token at `POST /inbound/register/{agent_id}` (sent on save and
   automatically re-sent on every app launch).
2. You trigger `POST /admin/ring/{agent_id}` (or `scripts/ring.py`) → when the
   ring needs your agent before the answer (inline credentials, or pre-connect,
   the default for apps that support it) the engine starts it in a room first,
   then sends a **VoIP push** to Apple once the agent is in that room → the
   phone rings.
3. The app fetches its credentials from your pairing endpoint
   (`/connect/{agent_id}`), during the ring with pre-connect (it then gets that
   room) or after the user answers without it (exactly like an outgoing call:
   your agent is dispatched then), and joins the room.

!!! note "Device + paid account only"
    None of this runs in the iOS Simulator (no PushKit, no CallKit), and the push
    requires a **paid Apple Developer account**. Verify on hardware.

## One-time Apple setup

Because Conduit is self-built, *you* hold the APNs key — your server talks to
Apple directly, and the user's push token never travels anywhere else.

1. **Enable Push Notifications on the App ID.**
   [developer.apple.com](https://developer.apple.com/account) → Certificates,
   Identifiers & Profiles → **Identifiers** → your Conduit App ID → check
   **Push Notifications** → Save. Rebuild + reinstall the app afterwards.
2. **Create an APNs auth key.** Same portal → **Keys** → **+** → enable **Apple
   Push Notifications service (APNs)** → register, then **download the `.p8`** (you
   get exactly one download — keep it safe) and note the **Key ID**.
3. **Note your Team ID.** Membership page, top right.

The `.p8` is a secret: never commit it (the repo gitignores `*.p8`) and never
paste its contents into a log or chat.

## Engine configuration

| Variable | What |
|---|---|
| `APNS_KEY_PATH` | Path to the `.p8` file (local runs) |
| `APNS_KEY_BASE64` | …or the key's contents, base64-encoded (hosted platforms): `base64 -i AuthKey_XXXXXXXXXX.p8 \| tr -d '\n'` |
| `APNS_KEY_ID` | The key's ID from the portal |
| `APNS_TEAM_ID` | Your Apple Developer Team ID |
| `APNS_USE_SANDBOX` | Optional. The engine rings both APNs environments and falls back automatically, so you rarely set this — it only picks which host is tried *first*. Leave unset/`false` for **production** (App Store / TestFlight, the normal case); set `true` to try **sandbox** first while iterating on a dev-signed Xcode build (skips one round-trip) |
| `APNS_TOPIC` | Optional override; normally derived as `<registered bundle id>.voip` |

Set either `APNS_KEY_PATH` or `APNS_KEY_BASE64`; the engine validates these at the
moment you ring, not at boot, so the rest of the engine runs fine without them.

!!! note "Which APNs environment? (production vs. sandbox)"
    A VoIP device token is valid on only **one** APNs environment, decided by how the
    **app** was signed — and the token doesn't reveal which, so the engine tries one
    host and automatically falls back to the other. You normally don't configure this:

    - **Production — the normal route.** A Conduit build installed from **TestFlight or
      the App Store** registers a production token. This is the default; ring it as-is.
    - **Sandbox — only if you fork the app.** A build you run from **Xcode onto your own
      device** is dev-signed and registers a sandbox token. It still rings via the
      fallback, but set `APNS_USE_SANDBOX=true` to try sandbox first and skip a wasted
      round-trip while you develop.

## Persistence: the registry and the (optional) volume

Registrations are stored in a **SQLite file** at `REGISTRY_DB_PATH` (default
`registry.db` in the working directory), alongside direct-mode room registrations.

Be clear about what durable storage here actually defends against — it may not be
worth the effort for you:

- **Without durable storage** (default on platforms with ephemeral filesystems,
  e.g. Railway without a volume): a **redeploy wipes the registry**. Inbound
  ringing then fails until the user next opens the app (any launch silently
  re-registers the token — nothing to reconfigure), and direct-mode webhook
  dispatch fails until you re-run `scripts/provision.py`. Pairing-mode outgoing
  calls are unaffected.
- **With durable storage**: registrations survive redeploys; your agent can ring
  the user at any time without depending on them having opened the app since the
  last deploy.

If you open the app daily and use pairing mode, skipping the volume is a
reasonable choice — the degradation is a self-healing inconvenience. If the whole
point of your agent is *proactive* calls, mount one:

```bash
# Railway: dashboard → service → Settings → Volumes → mount at /data
# then set:
REGISTRY_DB_PATH=/data/registry.db
```

## App-side setup

In Conduit → Add/Edit Agent:

1. Toggle **Let this agent call me**.
2. Set the **registration endpoint** to `https://<host>/inbound/register/<agent_id>`
   (e.g. `…/inbound/register/live`) — it's pre-filled from the pairing endpoint, so
   you'll usually just change `connect` to `inbound/register`.

The app POSTs its token immediately and on every launch; you should see
`inbound.registered` in the engine logs. Newer app builds also send the agent's
`display_name` and `handle` (the caller name and CallKit handle); the engine stores
them with the token and echoes them in every ring push. Older builds omit them, and
the push then omits the keys too — the app rings under its own name for the agent.
`scripts/ring.py` prints the name it rang as. Newer builds also send
`push_features`, the optional push features their call engine supports (today
`cancel`, `ring_timeout` and `preconnect`); the engine stores the list, keeping names it
doesn't know, and uses a feature only with a registration that lists it. Older
builds omit it, which the engine stores as an empty list. Current builds also
send `transport`, the transport the agent calls over in the app (the same value
as the `transport` of its `/connect` body): the room a ring prepares before the
push is made on it. Older builds omit it; a pre-connected pairing ring for them
then prepares nothing and waits for nothing (the app's request during the ring
makes the room), since a room on the wrong transport would only delay the ring
and be thrown away. Existing registry databases pick up the new columns
automatically on the next start.

Deleting the agent in the app sends a best-effort `DELETE` to the same endpoint — the engine drops the registration
(`inbound.unregistered`) and `/admin/ring` returns 404 from then on.

## Ringing the device

```bash
uv run python scripts/ring.py --agent live --base-url https://<host>
```

or raw:

```bash
curl -s -X POST https://<host>/admin/ring/live \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" -d '{}'
```

Two modes:

- **Pairing (default)** — the push carries no credentials, only `agent_id` +
  `call_id` (and `status_url`, plus the caller `display_name` and `handle` when the
  app registered them, and `preconnect`, below). Nothing sensitive rides the
  push. With pre-connect, the default for an app that lists it, the engine
  prepares the room and a ring bot **before the push** and hands that room to
  the app's `/connect/{agent_id}` during the ring, so the agent is in the room
  on pickup; the bot ends on a decline or any other non-answer (below). Without
  pre-connect (`--preconnect none`, `--no-wait`, or an app that does not list
  it) the app resolves `/connect/{agent_id}` after the user **answers**, and **a
  declined ring costs nothing** (no room, no bot).
- **Inline (`--inline` / `{"inline": true}`)** — the engine provisions a room and
  embeds `room_url` + `token` in the push. The bot is **dispatched before the
  push**, so the agent is already in the room on pickup. The engine ends that
  bot when the ring's first receipt is anything but `answered` (a decline, busy,
  Focus, a timeout, a cancel); with no receipt at all it runs (billing) until
  `PIPELINE_IDLE_TIMEOUT_SECS` reaps it, or, for a ring bot, until its ring
  deadline. Pairing with pre-connect gets the agent just as ready, without
  credentials in the push.

    !!! warning "Inline must match the app's transport"
        The app joins inline credentials over the transport **configured for that
        agent in the app**. Pass `--transport daily|livekit` to match it — a
        mismatch (e.g. a Daily room pushed to an agent the app dials over LiveKit)
        fails at answer time. Without `--transport` the engine uses the
        transport the app registered for the agent, and for an app that
        registered none the agent's own default. Pairing mode can't mismatch:
        the app negotiates the transport in its `/connect` call. A pairing
        ring's room prepared at ring time uses `--transport`, else the
        registered transport, and with neither prepares nothing; when the app
        asks for another, it gets a fresh room and the prepared one is ended.

### Agent-first ringing

So the agent is ready when the user picks up, a ring whose agent starts before
the push (every `--inline` ring, and a pre-connected pairing ring) is pushed only
once the agent's bot **has joined its room**. The bot (started with
`--report-joined`) says so on its stdout, which the engine reads, as soon as its
transport reports the join. The wait is bounded by `RING_BOT_WAIT_SECS` (default 8; observed joins take
2 to 7 s): past it, or as soon as the bot exits, the push goes out anyway, so a
slow or broken agent never blocks a ring. `0` turns agent-first ringing off for
the whole engine; for one ring, `--no-wait` (`{"wait_for_bot": false}`) pushes at
once, and a pairing ring then prepares nothing (its agent starts at the app's
request, as without pre-connect).

The ring response says how it went: `bot_in_room` is `true` when the bot had
joined when the push went out, `false` when the wait ran out or the bot exited,
and `bot_wait_secs` is how long the push waited; both are `null` for a ring that
did not wait. The engine logs `ring.waiting_for_bot` (with the `call_id`, so you
can cancel during the wait), `ring.bot_wait` (`outcome` = `joined`, `timeout`,
`exited` or `withdrawn`) and `ring.sent` with the same fields.

```
dispatch bot ──► bot joins the room ──► push ──► phone rings ──► answer
               (≤ RING_BOT_WAIT_SECS)        (pairing + pre-connect: /connect
                                              during the ring gets that room)
```

The wait never shortens the ring: a ring bot's deadline is the ring's timeout
plus `RING_DEADLINE_MARGIN_SECS` plus `RING_BOT_WAIT_SECS`, counted from the
bot's start. A ring canceled while the engine waits is never pushed (the cancel
answers `"method": "before_push"` and ends the bot; the ring request answers
`409` `{"call_id": …, "status": "canceled", "reason": "ring ended"}`), and a
receipt for it during the wait does the same. A push APNs rejects ends the bot
started for it.

### When the user picks up

The rule for any agent you ring with: **start your agent first and send the push
when it is in the room** (bounded, so a slow agent never blocks the ring), and ask
for pre-connect on every ring. The phone joins within a fraction of a second; what
the user waits for is your agent's start. What the user experiences, with Conduit:

| Case | What the user experiences |
|---|---|
| Ready at the answer (`media`, agent in the room before the answer) | Connected the moment they pick up; the app says nothing; `call-connected` reaches the agent when iOS activates the audio, a fraction of a second later. |
| Answered before the agent was there | Connecting, with no ringback; "Connecting" once if still connecting a second after the answer; connected the moment the agent arrives (no minimum for answered calls), then "Connected" and `call-connected`. |
| Credentials only during the ring (`credentials`, or SmallWebRTC) | The phone joins at the answer; connecting for the join plus the agent's readiness, short when the agent is already in the room; same sounds as above. |
| Pre-connect failed | The ring keeps ringing; the answer connects with an ordinary `/connect` (no `ring`), which starts a fresh agent. |

An agent that never arrives fails the call as "Agent didn't join": 30 s after the
phone's join, then, for a pre-connected ring that was answered, once more after
the ordinary request. The full contract is [Inbound calls (contract)](../INBOUND_CALLS.md),
section 5.

### Ring timeout and pre-connect

Two ring options for Conduit builds on call engine 0.2+ (older builds ignore
them and ring as before; the engine sends each only to a registration that lists
it):

```bash
uv run python scripts/ring.py --agent live --ring-timeout 30 --preconnect media
# raw: -d '{"ring_timeout": 30, "preconnect": "media"}'
uv run python scripts/ring.py --agent live --preconnect none   # a plain ring
# raw: -d '{"preconnect": "none"}'
```

- **`ring_timeout`** shortens this ring (the app clamps it to at least 10 s and
  to its own timeout, 60 s by default). An unanswered ring then reports
  `unanswered`. The engine puts it in the push only when the registration lists
  the `ring_timeout` push feature; otherwise the phone rings for its own
  default, the ring bot's deadline assumes that default, and the ring response's
  `ring_timeout` is `null`.
- **`preconnect`** asks the app to prepare while the phone rings. **Every ring
  asks for it by default**: the best tier the registration takes, `media` when it
  lists the `preconnect` push feature and the `call-connected` call signal,
  `credentials` when it lists the feature only. `--preconnect credentials|media`
  asks for one tier, and `--preconnect none` (`{"preconnect": "none"}`) opts out:
  a plain ring. A registration that does not list the `preconnect` push feature
  gets a ring exactly as if it had not been requested: no `preconnect` key (the
  same push as before pre-connect existed), no ring bot (an `--inline` bot is
  then a plain inline bot), the ring response's `preconnect` is `null`, and, for
  an explicit tier, the engine logs `ring.preconnect_unsupported`. A `media`
  request to a registration that does not list the `call-connected` call signal
  is sent as `credentials` (the response says so, and the engine logs
  `ring.preconnect_media_needs_call_connected`): only `call-connected` would tell
  a bot that met the phone in the room that the user answered. When it is sent:
  `credentials` fetches `/connect/{agent_id}` during the ring; `media` also
  joins the room before the answer (only where the transport supports it: LiveKit
  and Daily do, Daily with the agent's audio unsubscribed until the answer;
  SmallWebRTC stays at `credentials`). In pairing mode the app's
  `/connect` then carries `"ring": {"call_id", "joins_before_answer"}`. The
  engine has already prepared a room and **ring bot** for the ring (Daily and
  LiveKit; SmallWebRTC has no room, its bot starts at the app's offer), and the
  first such request gets that room, with no second bot. A later request for the
  ring, or one the prepared bot does not fit (another transport, a phone that
  will join before the answer when the bot was prepared for `credentials`, or
  `call_signals` that differ from the registration's), or one after that bot
  exited, gets a fresh room and ring bot as before (an unfit prepared bot is
  ended). A request without `ring` (after the answer, or a reconnect) always gets
  a fresh room. If the ring is `answered` before its prepared room was taken, the
  engine keeps that bot `PREPARED_CLAIM_GRACE_SECS` (10) for the phone's request
  for the ring, which may still be on the way (the receipt is sent at the
  answer; most likely on a cold launch answered quickly): a request in that time
  takes the room and its agent. After it (an app that did not prepare connects
  with a request of its own) the bot is ended. If preparing fails (say the transport isn't configured),
  the ring still goes out and that request provisions as before. With
  `--inline` the ring bot is dispatched at ring time.
  If that `/connect` lands after the ring already ended (a declined, busy,
  unanswered or canceled receipt, or the engine's own cancel; for example the user
  declined before the phone woke), the engine creates no room and dispatches no
  bot: it answers `409` `{"call_id": …, "status": …, "reason": "ring ended"}`,
  which the app treats as a failed pre-connect. A receipt that lands while the
  room is being made ends the bot just dispatched and gets the same `409`. If the
  ring was `answered` first, the pairing proceeds and the bot is given that
  receipt as soon as it exists.

A ring bot differs from a normal bot in three ways:

- It ends by itself if nobody answers within the ring's timeout (at least 10 s)
  plus `RING_DEADLINE_MARGIN_SECS` (15), plus `RING_BOT_WAIT_SECS` (8) for a bot
  started before the push, which may go out that much later (agent-first
  ringing, above). When the push carried no `ring_timeout`
  the engine cannot know how long the phone will ring, since the app's timeout is
  configurable (60 s by default, longer or unlimited if the user changed it), so it
  assumes `RING_TIMEOUT_SECS` (default 60, must be above 0): set it to match your
  app, or a bot ends mid-ring on a phone still ringing. A sender that wants a firm
  bound should always send `ring_timeout`.
- Like every bot for an app that lists `call-connected` (in its `/connect` body,
  or, for an `--inline` ring, its registration), it is dispatched with
  `--await-connected`: no audio and no greeting until the app's `call-connected`
  message, or, as a fallback for a lost one, `CALL_CONNECTED_GRACE_SECS` (default
  10, at least 5 as the push contract asks) after it knows the user answered and
  the device is in the room, whichever is later. For `media`
  (`--joins-before-answer`) the device's joining is not the answer: the answer is
  `call-connected` or the ring's `answered` receipt (relayed to the bot by the
  engine). The app sends the receipt at the moment of answer, before its audio is
  up and often before it has (re)joined, so the receipt only starts the fallback
  wait. The device leaving the room stops that wait, and its return starts it
  again in full. The receipt stops the ring deadline at once.
- The ring's first receipt steers it: `answered` starts that fallback, any other
  status ends it at once. (A plain inline ring's bot is ended the same way, but has no deadline
  and no control pipe.)

The engine tracks rings in memory (`app/rings.py`), so a dispatcher restart
forgets them; ring bots still end through their deadline.

### Canceling a ring

```bash
uv run python scripts/ring.py --agent live --cancel <call_id>      # withdraw a ring
uv run python scripts/ring.py --agent live --cancel-after 8        # ring, wait 8 s, withdraw it
# raw: POST /admin/ring/{agent_id}/cancel  {"call_id": "<call_id>"}
```

- `404` if the engine doesn't know that `call_id` for this agent; `409` once
  the ring's receipt arrived (it was answered, declined, …), after a cancel,
  when the ring bot has itself seen the call answered (below), or when the device
  can't take a cancel push (below).
- A ring the engine is still holding for its bot (agent-first ringing) is
  withdrawn **before its push**: the engine ends the bot and never sends the
  push, and answers `{"method": "before_push", "bot_ended": true}`.
- A `media` ring whose phone is in the room (Daily presence API / LiveKit
  `ListParticipants`) is canceled **in band**: the engine ends the bot, the app
  takes the agent leaving as the cancel and reports `canceled`. No push.
- Otherwise, if the registration lists the `cancel` push feature, the engine
  sends a cancel push, `{"action": "cancel", "call_id": …}` without `agent_id`,
  and ends the ring's bot if it has one. Cancel only rings you expect to be
  ringing.
- A cancel never ends the bot of an answered call. After the `answered` receipt
  the engine refuses with `409` (`status` `answered`, `reason` `ring ended`)
  without touching the bot or sending a push. Before the receipt, the engine does
  not signal a ring bot: it asks it (a `cancel` line on the bot's stdin; the
  verdict returns on its stdout, so the bot is the one place that knows) and the
  bot ends itself unless it has seen `call-connected`, the receipt, or, for a ring
  the phone joins only after the answer, the human join. A refusal is `409` with
  `{"call_id": …, "status": "answered", "reason": "ring answered"}`, the bot and
  ring are left alone, and on the push branch the cancel push has already gone out
  (the answered phone ignores it). A bot that cannot be asked (a plain inline bot
  has no control pipe; or it is gone, or silent for 3 s) is force-ended as before.
  The residual race is the answered receipt's flight time: the user answered, but
  neither the receipt nor `call-connected` has reached the engine or bot yet.
- If it doesn't (an app build that sent no `push_features`, or one without
  `cancel`), the engine sends nothing, since that app would show the push as a
  brief incoming-call flash. It returns `409` with
  `{"call_id": …, "status": null, "reason": "cancel unsupported by device"}` and
  leaves the ring and its bot alone: the ring ends when it times out or the user
  declines.

### Hold

Conduit's calls cannot be held: a phone call the user accepts ends the call, and
Conduit never sends `call-held` or `call-resumed`. An app on the call engine with
its experimental hold turned on does: when the user puts the call on hold (taking
or placing a cellular call, or holding it in the app), it sends `call-held` and,
later, `call-resumed`,
each again if it did not leave the device and `call-held` again after a
reconnect. The bot stops talking and hears nothing while held, and if the phone drops out of the room while held it waits
`HELD_GRACE_SECS` (default 600) instead of `HUMAN_ABSENT_GRACE_SECS`.

### The `tone` test agent

`tone` plays a continuous 440 Hz tone from the moment a human joins the room
and ignores client-ready and `call-connected`. It needs no model keys. Ring it
pre-connected to hear whether a ringing phone lets any audio out:

```bash
uv run python scripts/ring.py --agent tone --inline --preconnect media --transport livekit
```

Register the app's inbound toggle against `/inbound/register/tone` first. Any
tone before you answer is a leak; after you answer you should hear it at once.

## Ring-status receipts

Every ring's push carries a `status_url` pointing back at the engine, and the app
reports how the ring ended — so you can tell from the engine logs whether the user
**answered**, **declined**, was **busy** in another call, never saw the ring
because **Focus/DND suppressed it**, let it time out (**unanswered**), or you
**canceled** it. The engine accepts any status string (newer apps may add more)
and logs unknown ones with `known=False`:

```
inbound.ring_status agent=live call_id=… status=suppressed_by_focus
```

That last one is the valuable signal: APNs said `200`, the engine did everything
right, and the phone still didn't ring. If your agent escalates (retry later, fall
back to a text channel), this receipt is the hook. The receipt is fire-and-forget
from the app. The engine logs it, and uses a ring's first receipt to release or
end the bot dispatched for it (inline and pre-connect rings above) — extend the `/inbound/status` route if your agent should
react further.

The engine derives `status_url` from the ring request's own URL, which behind a
TLS-terminating proxy (any hosted platform) requires uvicorn's
`--proxy-headers --forwarded-allow-ips="*"` — already part of this repo's start
commands. A status receipt also reveals the user's busy/Focus state — fine here
(it's the user's own server), but don't forward receipts elsewhere.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `404` from `/admin/ring` | No registration yet — is the toggle on, and does the registration URL end in `/inbound/register/<agent_id>`? |
| `502` · `BadDeviceToken` | The token was rejected by **both** APNs environments, so it's stale or malformed (e.g. the app was reinstalled) — re-enable inbound in the app to re-register |
| `502` · `InvalidProviderToken` | Wrong `APNS_KEY_ID`, `APNS_TEAM_ID`, or key contents |
| `502` · `TopicDisallowed` | Push Notifications not enabled on the App ID, or the topic doesn't match `<bundle id>.voip` |
| `502` · `Unregistered` | The token is stale (app reinstalled); the engine evicted it — re-enable inbound in the app |
| `503` | APNs vars not set on the engine (or, for `--inline`, the transport/model keys are missing) |
| `409` from `/admin/ring` · `ring ended` | The ring was canceled, or got a receipt, while the engine waited for its agent to join the room; its push never went out |
| `bot_in_room: false` in the ring response | The agent's bot hadn't joined within `RING_BOT_WAIT_SECS` (or it exited): the ring went out anyway. Check the bot's logs; raise the bound if your agent is just slow to start |
| APNs `200` but no ring | **Most often Focus / Do Not Disturb** — iOS filters the call, so it doesn't ring or alert the lock screen but **is logged in the app's Recents as a missed call** (the status receipt reads `suppressed_by_focus`). Other causes: the app must be on a real device; one call at a time (a ring during an active call is logged as missed, never breaks through); an unknown agent UUID in the app ends the call gracefully |
