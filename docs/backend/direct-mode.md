# Direct mode & the SFU webhooks

Direct mode is the credential flow where the app holds a **stable room +
long-lived token** — provisioned once and pasted into the app — and joins that
fixed room at call time. The engine isn't told to start a bot; instead the SFU
fires a **participant-joined webhook** and the engine dispatches the agent
reactively.

!!! tip "If you just want to test an agent, use pairing"
    `POST /connect/{agent}` needs only your SFU API key and no public URL. The
    webhook machinery on this page is required *only* for direct mode.

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

Expires: 2026-07-09T…  (gates the initial connect only, not reconnects)
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

## Operational caveats

- **Ephemeral tunnel URLs** — quick tunnels get a new host every restart;
  re-register (Daily updates in place; LiveKit: edit in the dashboard).
- **Failed webhooks go dormant** — if your endpoint stops returning `200`, Daily
  marks the webhook `FAILED` after 3 failures and stops sending; re-register to
  reactivate.
- **Redeploys orphan provisioned rooms.** The engine's registry is in-memory: a
  restart wipes every room recorded by `/credentials`, so the webhook fires but
  nobody is dispatched and the call connects to silence. Re-provision after a
  redeploy, or wire a persistent registry (`app/registry.py` is the seam) before
  relying on direct mode in production. Pairing is unaffected.
