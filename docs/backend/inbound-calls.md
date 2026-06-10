# Inbound calls (your agent rings you)

The engine can make Conduit **ring the user's iPhone** — a real lock-screen /
CarPlay incoming call, agent-initiated. This page is the operational guide for the
reference engine; the app↔server contract it implements is
[Inbound calls (contract)](../INBOUND_CALLS.md).

How it fits together:

1. The user enables **"Let this agent call me"** in the app → the app registers its
   VoIP push token at `POST /inbound/register/{agent_id}` (automatically re-sent on
   every app launch).
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
| `APNS_USE_SANDBOX` | Default `true` — correct for Xcode (dev-signed) builds. Set `false` only for TestFlight / App Store distribution signing |
| `APNS_TOPIC` | Optional override; normally derived as `<registered bundle id>.voip` |

Set either `APNS_KEY_PATH` or `APNS_KEY_BASE64`; the engine validates these at the
moment you ring, not at boot, so the rest of the engine runs fine without them.

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
`inbound.registered` in the engine logs.

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

- **Pairing (default)** — the push carries only `agent_id` + `call_id`; the app
  resolves `/connect/{agent_id}` after the user **answers**. Nothing sensitive
  rides the push, and **a declined ring costs nothing** (no room, no bot).
- **Inline (`--inline` / `{"inline": true}`)** — the engine provisions a room and
  embeds `room_url` + `token` in the push. The bot is **dispatched before the user
  answers**, so the agent is already in the room on pickup — but a declined ring
  leaves it running (billing) until `PIPELINE_IDLE_TIMEOUT_SECS` reaps it. Prefer
  pairing unless you need the agent mid-sentence-ready at pickup.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `404` from `/admin/ring` | No registration yet — is the toggle on, and does the registration URL end in `/inbound/register/<agent_id>`? |
| `502` · `BadDeviceToken` | APNs environment mismatch — `APNS_USE_SANDBOX` must match the app's signing (Xcode build → sandbox/`true`) |
| `502` · `InvalidProviderToken` | Wrong `APNS_KEY_ID`, `APNS_TEAM_ID`, or key contents |
| `502` · `TopicDisallowed` | Push Notifications not enabled on the App ID, or the topic doesn't match `<bundle id>.voip` |
| `502` · `Unregistered` | The token is stale (app reinstalled); the engine evicted it — re-enable inbound in the app |
| `503` | APNs vars not set on the engine (or, for `--inline`, the transport/model keys are missing) |
| APNs `200` but no ring | The app must be on a real device; one call at a time (a ring during an active call is ignored); an unknown agent UUID in the app ends the call gracefully |
