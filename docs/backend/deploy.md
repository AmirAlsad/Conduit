# Deploy

The engine is a single always-on web process whose only inbound surface is HTTPS —
your agent dials *out* to the Daily/LiveKit cloud SFU, so there's no inbound
UDP/TURN/media termination to operate. Two constraints shape every deployment:

- **Always-on.** It must answer `/connect` and webhooks without a cold start —
  disable any serverless/app-sleeping mode.
- **Single process.** Idempotent dispatch relies on per-room locks that only
  serialize within one event loop (the SQLite registry doesn't change this).
  Don't run replicas or `--workers > 1`.

## Docker / any host

A `Dockerfile` is provided (Python 3.12 + uv, `uv sync --frozen`, binds
`${PORT:-8000}`):

```bash
docker build -t conduit-engine .
docker run -p 8000:8000 --env-file .env conduit-engine
```

`.dockerignore` keeps `.venv`, `.env`, and `node_modules` out of the image —
inject secrets through your platform, never bake them in.

### Forwarded headers

The engine builds absolute URLs from the request it is serving: the
`status_url` in every ring push, and a SmallWebRTC offer URL. Behind a
TLS-terminating proxy that request arrives as plain `http`, so uvicorn runs with
`--proxy-headers` and takes the scheme (and client address) from the proxy's
`X-Forwarded-Proto` / `X-Forwarded-For`, but only from addresses it trusts:

- **Dockerfile:** trusts `FORWARDED_ALLOW_IPS`, uvicorn's default `127.0.0.1`.
  Set it to your proxy's address (`-e FORWARDED_ALLOW_IPS=10.0.0.5`). Set `*`
  only when the container is reachable solely through that proxy.
- **Railway (`railway.json`, `Procfile`):** `--forwarded-allow-ips="*"`, because
  Railway's edge proxy has no fixed address and is the only way in.

Trusting `*` on a port anyone can reach lets any client choose the scheme and
client address the engine sees. That doesn't bypass the bearer key, but it
falsifies logs and the URLs handed back to that client.

## Railway

`railway.json` sets the start command and the `/health` check. Push the repo,
then **disable Serverless / App Sleeping** in the service settings and set the
environment variables.

For registry durability across redeploys (direct-mode rooms + inbound VoIP
tokens), mount a **volume** at `/data` and set `REGISTRY_DB_PATH=/data/registry.db`
— see [Inbound calls](inbound-calls.md) for what this defends against and when
it's fine to skip.

## After deploy

1. Set env vars on the platform — at minimum `ENGINE_API_KEY` (generate it with
   `openssl rand -hex 32`; the engine refuses to start with it empty or an
   example value) plus your SFU keys; `.env` is local-only and gitignored.
2. **Direct mode only:** register the SFU webhook once against your public URL
   (it persists across redeploys) — Daily via
   `scripts/daily_webhook.py register --base-url https://<host>`, LiveKit via the
   Cloud dashboard. Details: [Direct mode & webhooks](direct-mode.md).
3. Point the app's pairing endpoint at `https://<host>/connect/<agent>` with your
   `ENGINE_API_KEY`, or provision direct credentials with `scripts/provision.py`.

## Before you expose it

- **The pairing key is the admin key.** This reference server has one
  `ENGINE_API_KEY`: the phone sends it to pair, register and post receipts, and
  the same key rings the phone, ends agents, mints long-lived room tokens and can
  overwrite the push registration (redirecting the agent's rings to another
  phone). The QR from `scripts/pair.py` embeds it unless `--no-key`. Keep it
  secret, and rotate it (new key, restart, re-enter in the app) if it leaks. A
  production server should use separate pairing and admin keys; this one does not.
- **HTTPS only** on anything but a LAN you trust.

## Operational caveats

- **Redeploys kill in-flight agents** and drop active calls — deploy when quiet.
- **Redeploys wipe the registry unless it's on durable storage** — direct-mode
  rooms are orphaned and inbound VoIP tokens forgotten until re-registered.
  Pairing is unaffected. Fix: a volume + `REGISTRY_DB_PATH` (see
  [Inbound calls](inbound-calls.md)).
- Keep `HUMAN_ABSENT_GRACE_SECS` (default 120) above the app's reconnect budget,
  about 100 s for Conduit (up to 30 s of SDK recovery, then attempts after 1, 2,
  4, 8, 16 and 30 s, plus connect time) — the agent is a billed participant
  during the window, but cutting it short breaks the reconnects that return to
  the same room (SDK recovery; direct and inline credentials). A pairing call's
  app-level reconnect gets a new room and agent from `/connect`, and its old agent
  waits the window out.
