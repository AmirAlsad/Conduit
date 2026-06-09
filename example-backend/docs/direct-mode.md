# Direct mode & the SFU webhooks

This guide moved to the published docs site so it can't drift from the rest of the
connection documentation:

**→ [Direct mode & webhooks](https://amiralsad.github.io/Conduit/backend/direct-mode/)**
(source: [`docs/backend/direct-mode.md`](../../docs/backend/direct-mode.md))

The short version: direct mode mints a stable room + long-lived token once
(`uv run python scripts/provision.py --transport daily|livekit` prints exactly
what to paste into the app) and dispatches the agent reactively via the SFU's
participant-joined webhook — so the engine needs a public URL and a registered
webhook. Daily's webhook is registered by script
([`scripts/daily_webhook.py`](../scripts/daily_webhook.py); API-only, no
dashboard); LiveKit's is registered in the LiveKit Cloud dashboard (Settings →
Webhooks → `/webhooks/livekit`; dashboard-only, no API), verified with your
existing `LIVEKIT_API_KEY`/`SECRET`. If you just want to test an agent, use
pairing — no webhook needed.
