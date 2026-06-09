# Deploy

The engine is a single always-on web process whose only inbound surface is HTTPS —
your agent dials *out* to the Daily/LiveKit cloud SFU, so there's no inbound
UDP/TURN/media termination to operate. Two constraints shape every deployment:

- **Always-on.** It must answer `/connect` and webhooks without a cold start —
  disable any serverless/app-sleeping mode.
- **Single process.** Idempotent dispatch relies on an in-memory registry and
  per-room locks, which only serialize within one event loop. Don't run replicas
  or `--workers > 1` until the registry is moved to a shared store.

## Docker / any host

A `Dockerfile` is provided (Python 3.12 + uv, `uv sync --frozen`, binds
`${PORT:-8000}`):

```bash
docker build -t conduit-engine .
docker run -p 8000:8000 --env-file .env conduit-engine
```

`.dockerignore` keeps `.venv`, `.env`, and `node_modules` out of the image —
inject secrets through your platform, never bake them in.

## Railway

`railway.json` sets the start command and the `/health` check. Push the repo,
then **disable Serverless / App Sleeping** in the service settings and set the
environment variables.

## After deploy

1. Set env vars on the platform — at minimum `ENGINE_API_KEY` plus your SFU keys;
   `.env` is local-only and gitignored.
2. **Direct mode only:** register the SFU webhook once against your public URL
   (it persists across redeploys) — Daily via
   `scripts/daily_webhook.py register --base-url https://<host>`, LiveKit via the
   Cloud dashboard. Details: [Direct mode & webhooks](direct-mode.md).
3. Point the app's pairing endpoint at `https://<host>/connect/<agent>` with your
   `ENGINE_API_KEY`, or provision direct credentials with `scripts/provision.py`.

## Operational caveats

- **Redeploys kill in-flight agents** and drop active calls — deploy when quiet.
- **Redeploys orphan direct-mode rooms** (in-memory registry; see
  [Direct mode](direct-mode.md)). Pairing is unaffected.
- Keep `HUMAN_ABSENT_GRACE_SECS` ≥ the app's reconnect-with-backoff budget — the
  agent is a billed participant during the window, but cutting it short breaks
  reconnection, Conduit's headline feature.
