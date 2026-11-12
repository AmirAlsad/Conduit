# Inbound calls (your agent rings you)

The engine can make Conduit **ring the user's iPhone** — a real lock-screen /
CarPlay incoming call, agent-initiated. This page is the operational guide for the
reference engine; the app↔server contract it implements is
[Inbound calls (contract)](../INBOUND_CALLS.md).

How it fits together:

1. The user enables **"Let this agent call me"** in the app → the app registers its
   VoIP push token at `POST /inbound/register/{agent_id}` (sent on save and
   automatically re-sent on every app launch).
2. You trigger `POST /admin/ring/{agent_id}` (or `scripts/ring.py`) → the engine
   sends a **VoIP push** to Apple → the phone rings.
3. The user answers → the app resolves your pairing endpoint
   (`/connect/{agent_id}`) exactly like an outgoing call, and your agent is
   dispatched into the room.

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
`cancel` and `ring_timeout`); the engine stores the list, keeping names it
doesn't know, and uses a feature only with a registration that lists it. Older
builds omit it, which the engine stores as an empty list. Existing registry
databases pick up the new columns automatically on the next start.

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
  app registered them); the app resolves `/connect/{agent_id}` after the user
  **answers**. Nothing sensitive rides the push, and **a declined ring costs nothing** (no room, no bot).
- **Inline (`--inline` / `{"inline": true}`)** — the engine provisions a room and
  embeds `room_url` + `token` in the push. The bot is **dispatched before the user
  answers**, so the agent is already in the room on pickup. The engine ends that
  bot when the ring's first receipt is anything but `answered` (a decline, busy,
  Focus, a timeout, a cancel); with no receipt at all it runs (billing) until
  `PIPELINE_IDLE_TIMEOUT_SECS` reaps it. Prefer pairing unless you need the agent
  mid-sentence-ready at pickup.

    !!! warning "Inline must match the app's transport"
        The app joins inline credentials over the transport **configured for that
        agent in the app**. Pass `--transport daily|livekit` to match it — a
        mismatch (e.g. a Daily room pushed to an agent the app dials over LiveKit)
        fails at answer time. Pairing mode can't mismatch: the app negotiates the
        transport in its `/connect` call.

### Ring timeout and pre-connect

Two optional ring options (Conduit builds on call engine 0.2+; older builds
ignore them and ring as before):

```bash
uv run python scripts/ring.py --agent live --ring-timeout 30 --preconnect media
# raw: -d '{"ring_timeout": 30, "preconnect": "media"}'
```

- **`ring_timeout`** shortens this ring (the app clamps it to at least 10 s and
  to its own timeout, 60 s by default). An unanswered ring then reports
  `unanswered`. The engine puts it in the push only when the registration lists
  the `ring_timeout` push feature; otherwise the phone rings for its own
  default, the ring bot's deadline assumes that default, and the ring response's
  `ring_timeout` is `null`.
- **`preconnect`** asks the app to prepare while the phone rings:
  `credentials` fetches `/connect/{agent_id}` during the ring; `media` also
  joins the room before the answer (only where the transport supports it; Daily
  stays at `credentials`). In pairing mode the app's `/connect` then carries
  `"ring": {"call_id", "await_answer"}`, and the engine dispatches a **ring bot**
  for it. With `--inline` the ring bot is dispatched at ring time.

A ring bot differs from a normal bot in three ways:

- It ends by itself if nobody answers within the ring's timeout (at least 10 s;
  `RING_TIMEOUT_SECS`, default 60, when the ring didn't set one) plus
  `RING_DEADLINE_MARGIN_SECS` (15).
- For `media` it is dispatched with `--await-answer`: no audio and no greeting
  until the app's `call-answered` message, or the ring's `answered` receipt
  (relayed to the bot by the engine; that covers an app without engine 0.2).
- The ring's first receipt steers it: `answered` releases it, any other status
  ends it. (A plain inline ring's bot is ended the same way, but has no deadline
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
  the ring's receipt arrived (it was answered, declined, …), after a cancel, or
  when the device can't take a cancel push (below).
- A `media` ring whose phone is in the room (Daily presence API / LiveKit
  `ListParticipants`) is canceled **in band**: the engine ends the bot, the app
  takes the agent leaving as the cancel and reports `canceled`. No push.
- Otherwise, if the registration lists the `cancel` push feature, the engine
  sends a cancel push, `{"action": "cancel", "call_id": …}` without `agent_id`,
  and ends the ring's bot if it has one. Cancel only rings you expect to be
  ringing.
- If it doesn't (an app build that sent no `push_features`, or one without
  `cancel`), the engine sends nothing, since that app would show the push as a
  brief incoming-call flash. It returns `409` with
  `{"call_id": …, "status": null, "reason": "cancel unsupported by device"}` and
  leaves the ring and its bot alone: the ring ends when it times out or the user
  declines.

### Hold

When the user puts the call on hold (e.g. to take a cellular call), the app
sends `call-held` and, later, `call-resumed`. The bot stops talking and hears
nothing while held, and if the phone drops out of the room while held it waits
`HELD_GRACE_SECS` (default 600) instead of `HUMAN_ABSENT_GRACE_SECS`.

### The `tone` test agent

`tone` plays a continuous 440 Hz tone from the moment a human joins the room
and ignores client-ready and `call-answered`. It needs no model keys. Ring it
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
| APNs `200` but no ring | **Most often Focus / Do Not Disturb** — iOS filters the call, so it doesn't ring or alert the lock screen but **is logged in the app's Recents as a missed call** (the status receipt reads `suppressed_by_focus`). Other causes: the app must be on a real device; one call at a time (a ring during an active call is logged as missed, never breaks through); an unknown agent UUID in the app ends the call gracefully |
