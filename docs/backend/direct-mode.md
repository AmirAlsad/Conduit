# Direct mode & the SFU webhooks

Direct mode is the credential flow where the app holds a **stable room +
long-lived token** — provisioned once and pasted into the app — and joins that
fixed room at call time. The engine isn't told to start a bot; instead the SFU
fires a **participant-joined webhook** and the engine dispatches the agent
reactively.

!!! tip "If you just want to test an agent, use pairing"
    `POST /connect/{agent}` needs only your SFU API key and no public URL. The
    webhook machinery on this page is required *only* for direct mode.

!!! warning "Before you expose the engine to a network"
    Generate `ENGINE_API_KEY` with `openssl rand -hex 32` (the engine refuses an
    empty or example key) and serve the engine over HTTPS. In this reference
    server the pairing key is also the admin key: it rings the phone, ends
    agents, mints long-lived room tokens and can redirect the agent's rings, so
    treat it (and any pairing QR that embeds it) as a secret. See
    [Deploy → Before you expose it](deploy.md#before-you-expose-it).

## Why direct mode needs a webhook (and pairing doesn't)

In pairing, the engine creates the room and dispatches the agent *inside the
request*. In direct mode the credentials are minted long before any call, and a
resident bot would bill connection-minutes around the clock — so dispatch must
happen **exactly at call time**, and the only thing that knows you just joined a
fixed room is the SFU. It tells the engine via a webhook, which means the SFU must
be able to reach your engine over the public internet.

## Provision: `scripts/provision.py`

The provision script calls `POST /credentials/{agent}` and prints exactly what the
app asks for:

```bash
uv run python scripts/provision.py --transport daily
uv run python scripts/provision.py --transport livekit --agent live --base-url https://<host>
```

```text
Direct credentials for agent 'loopback' (daily)
Paste into Conduit → Add Agent → Direct room (advanced):

  Room URL : https://your-domain.daily.co/abc123
  Token    : eyJhbGciOi…

Expires: 2026-07-09T…  (the app reuses this token for every call and reconnect; after it, provision again)
```

`ENGINE_API_KEY` is read from `.env`; `--json` dumps the raw payload.

## Register the webhook

=== "Daily"

    Daily webhooks are managed **only through Daily's REST API** (no dashboard),
    so the repo ships a registration script that reads `DAILY_API_KEY` /
    `DAILY_WEBHOOK_SECRET` from `.env` and registers your own HMAC secret —
    what Daily signs with always matches what the engine verifies with:

    ```bash
    uv run python scripts/daily_webhook.py register --base-url https://<your-public-host>
    uv run python scripts/daily_webhook.py list
    uv run python scripts/daily_webhook.py delete --uuid <uuid>
    ```

    Notes: webhooks require a credit card on the Daily account; they fire
    domain-wide (the engine ignores unknown rooms and the bot's own join); Daily
    probes the URL and requires a `200` before registering, so the dispatcher must
    be up and publicly reachable.

=== "LiveKit"

    The mirror image: **dashboard-only on LiveKit Cloud** (there is no
    registration API). Go to your project → **Settings → Webhooks** → add
    `https://<your-public-host>/webhooks/livekit`.

    There's no separate webhook secret — LiveKit signs each delivery with a JWT in
    the `Authorization` header, verified with the `LIVEKIT_API_KEY` /
    `LIVEKIT_API_SECRET` already in your `.env`.

    Self-hosted LiveKit registers webhooks in the server's `livekit.yaml`:

    ```yaml
    webhook:
      api_key: <your-api-key>
      urls:
        - https://<your-public-host>/webhooks/livekit
    ```

## Testing locally (with a tunnel)

Locally you have no public URL, so front the dispatcher with a tunnel:

```bash
# Terminal 1 — dispatcher
uv run uvicorn app.main:app --port 8000

# Terminal 2 — public tunnel (no account needed)
cloudflared tunnel --url http://localhost:8000     # or: ngrok http 8000

# Terminal 3 — point the SFU webhook at the tunnel host, then provision
uv run python scripts/daily_webhook.py register --base-url https://<random>.trycloudflare.com
uv run python scripts/provision.py --transport daily
```

Join the printed Room URL + Token. The SFU fires participant-joined → your tunnel
→ the engine dispatches the agent. Watch Terminal 1 for `webhook.daily_received`
then `dispatch.requested` / `dispatch.accepted`.

## When the agent speaks

Conduit sends `call-connected`
on every call, a direct room's included, but a fixed room's agent is never told so:
only a pairing request and the token registration carry `call_signals`. If you run
an agent in a fixed room for Conduit, **wait for `call-connected` before you greet,
with a short fallback** (greet anyway about 10 seconds after the device joined if
it has not come), and treat a later `call-connected` as the same call coming back.
If your agent greets as soon as the device joins or is ready instead, on a call the
user places the greeting plays over Conduit's ringback (the call shows connecting
for at least about 2.6 s) and then over its spoken "Connected", while the user's
mic stays closed until "Connected" has finished: the start of the greeting is lost
and the user cannot answer it at once. On a call your server rings, Conduit never
joins a fixed room before the user answers (it prepares at most the credentials it
already has), so the greeting cannot reach a ringing phone, but it can still overlap
"Connecting" and "Connected" while the answered call connects.

The reference engine's webhook-dispatched bots cannot tell which client joined (the
web test client sends no `call-connected`), so they greet when the client is ready,
as before; with Conduit that is the overlap described above. Use pairing for the
Conduit app: its bots wait for `call-connected`.

## Operational caveats

- **Ephemeral tunnel URLs** — quick tunnels get a new host every restart;
  re-register (Daily updates in place; LiveKit: edit in the dashboard).
- **Failed webhooks go dormant** — if your endpoint stops returning `200`, Daily
  marks the webhook `FAILED` after 3 failures and stops sending; re-register to
  reactivate.
- **Redeploys can orphan provisioned rooms.** The engine records the rooms
  `/credentials` made in a SQLite file (`REGISTRY_DB_PATH`, default
  `registry.db` in the working directory). On an ephemeral filesystem (Railway
  without a volume) a redeploy wipes it: the webhook fires, nobody is dispatched,
  and the app ends the call after 30 s as "Agent didn't join". Mount a volume and
  point `REGISTRY_DB_PATH` at it (see [Deploy](deploy.md)), or re-provision after
  a redeploy. Pairing is unaffected.
