# Direct mode & the Daily webhook

Direct mode is the credential flow where the app holds a **stable room + long-lived
token** (provisioned once via `POST /credentials`, pasted into the app) and joins
that fixed room at call time. The engine isn't told to start a bot — instead the
SFU fires a **participant-joined webhook** and the engine dispatches the bot
reactively. This doc covers the webhook end-to-end, because it's the one piece of
direct mode that isn't obvious.

## Why direct mode needs a webhook (and pairing doesn't)

In **pairing** (`POST /connect`) the engine creates the room and dispatches the bot
*inside the request*, then hands creds back. No callback needed.

In **direct** mode the credentials are minted long before the call and the bot
would bill connection-minutes around the clock if it sat resident. So dispatch has
to happen **exactly at call time** — and the only thing that knows a human just
joined a fixed room is the SFU. It tells the engine via a webhook. That means the
SFU has to be able to **reach your engine over the public internet**.

> **If you just want to test the agent, use pairing.** `POST /connect` needs only
> `DAILY_API_KEY` and no public URL. The webhook is required *only* for direct mode.

## The Daily webhook secret

`DAILY_WEBHOOK_SECRET` is Daily's **HMAC-SHA256 signing secret** (base-64). Daily
signs each webhook over `"{X-Webhook-Timestamp}.{body}"` and sends the result in the
`X-Webhook-Signature` header; the dispatcher recomputes it (both the `X-Webhook-Signature`
and `X-Webhook-Timestamp` headers must be present, or it's rejected 401) to prove the
request is really from Daily and not someone hitting your public `/webhooks/daily`.
Facts that trip people up:

- **There is no dashboard for Daily webhooks.** They are created/managed only through
  Daily's REST API. The secret doesn't exist until you *create* a webhook.
- **You can bring your own secret.** Daily accepts an `hmac` you supply at creation,
  base-64 encoded. This repo does exactly that: the value is already in your `.env`
  as `DAILY_WEBHOOK_SECRET`, and the registration script registers the webhook with
  that same value — so what Daily signs with always matches what the dispatcher
  verifies with. (If you instead let Daily auto-generate one, you'd have to copy it
  back into `.env`.)
- **Webhooks require a credit card** on the Daily account (a paid feature). If your
  Daily key came from Pipecat Cloud, the account may or may not have this unlocked —
  `daily_webhook.py list` returning `200` confirms it's enabled.
- **Webhooks are domain-wide** — one fires for *every* room on your Daily domain.
  The engine handles that: it ignores rooms it doesn't recognize and the bot's own
  join. You only need one webhook registration per environment.

## The registration script

[`scripts/daily_webhook.py`](../scripts/daily_webhook.py) wraps the REST API and
reads `DAILY_API_KEY` / `DAILY_WEBHOOK_SECRET` from your `.env`:

```bash
# Point Daily at your dispatcher (script appends /webhooks/daily):
uv run python scripts/daily_webhook.py register --base-url https://<your-public-host>

# Inspect / clean up:
uv run python scripts/daily_webhook.py list
uv run python scripts/daily_webhook.py delete --uuid <uuid>
```

`register` updates an existing webhook for that exact URL in place (no duplicates).
It will fail if the URL isn't publicly reachable — Daily probes it and requires a
`200` first, which the dispatcher returns to Daily's `{"test":"test"}` check.

## Testing direct mode locally (with a tunnel)

Locally you have no public URL, so you front the dispatcher with a tunnel.

```bash
# Terminal 1 — dispatcher (loads .env, including DAILY_WEBHOOK_SECRET)
uv run uvicorn app.main:app --port 8000

# Terminal 2 — public tunnel (no account needed)
cloudflared tunnel --url http://localhost:8000     # → https://<random>.trycloudflare.com
#   or:  ngrok http 8000

# Terminal 3 — register the webhook at the tunnel host
uv run python scripts/daily_webhook.py register --base-url https://<random>.trycloudflare.com

# Provision a direct-mode room and join it (web client / iOS)
curl -s -X POST http://localhost:8000/credentials \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"loopback","transport":"daily"}'
```

Join the returned `room_url` + `token`. Daily fires `participant.joined` → your
tunnel → `/webhooks/daily` → the dispatcher dispatches the bot. Watch Terminal 1
for `webhook.daily_received` then `dispatch.requested` / `dispatch.accepted`.

## Direct mode when deployed (Railway)

Deploying collapses Terminals 1 and 2 into the Railway service and its **stable
public URL**. So the only webhook-specific step left is the one-time registration,
pointed at the Railway URL instead of a tunnel:

```bash
uv run python scripts/daily_webhook.py register --base-url https://<your>.up.railway.app
```

This is a **one-time** action — the webhook persists on Daily across redeploys
(you don't re-register each deploy). What "deploy" itself entails, separately from
the webhook:

1. Push the repo to Railway (`railway.json` sets the start command + `/health`).
2. **Disable Serverless / App Sleeping** so the dispatcher can receive webhooks
   without a cold start.
3. Set the env vars on Railway — crucially the **same `DAILY_WEBHOOK_SECRET`** you
   registered with, plus `ENGINE_API_KEY`, `DAILY_API_KEY`, provider keys, etc.
   (`.env` is local-only / gitignored.)

## Operational caveats

- **Ephemeral tunnel URLs.** A `cloudflared`/`ngrok` quick tunnel gets a new host on
  every restart, so re-run `register` (it updates in place) when the host changes.
- **Webhooks persist and can go FAILED.** The webhook lives on Daily until you
  `delete` it. If its endpoint stops returning `200` (tunnel down), after 3 failed
  deliveries Daily marks it `FAILED` and stops sending; re-`register` the same URL to
  reactivate, or `delete` it.
- **⚠️ Redeploys orphan provisioned rooms.** The registry is in-memory, so a
  redeploy wipes every room recorded by `/credentials`. The webhook still fires, but
  the engine no longer recognizes the room and dispatches nobody — the call connects
  to silence. Re-provision after a redeploy, or wire a persistent `Registry`
  (`app/registry.py`) before relying on direct mode in production. Pairing is
  unaffected.

## LiveKit equivalent

LiveKit direct mode works the same way but registers in LiveKit's project webhook
settings (pointing at `/webhooks/livekit`); verification uses your
`LIVEKIT_API_KEY`/`SECRET`, not a separate secret. There's no Daily-style script
for it yet.
