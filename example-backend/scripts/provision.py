#!/usr/bin/env python
"""Mint direct-mode credentials and print exactly what to paste into Conduit.

Direct mode skips the per-call pairing endpoint: you provision a long-lived room
+ token once, paste them into the app's **Add Agent → Direct room (advanced)**
fields, and the engine dispatches the bot reactively when the SFU's webhook says
you joined. This script is that one-time provisioning call — it POSTs
``{base}/credentials/{agent}`` with your engine key and formats the response as
the two fields the app asks for.

Usage:
  uv run python scripts/provision.py --transport daily
  uv run python scripts/provision.py --transport livekit --agent live --base-url https://<host>

``--base-url`` is wherever the dispatcher is reachable (default
``http://localhost:8000``; falls back to ``PUBLIC_BASE_URL`` from ``.env`` when
set). ``ENGINE_API_KEY`` is read from ``.env``. Remember: dispatch needs the
matching webhook registered (Daily: ``scripts/daily_webhook.py register``;
LiveKit: the Cloud dashboard — see ``docs/direct-mode.md``).
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Make the project root importable so we reuse the same .env-backed settings.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import settings  # noqa: E402

# Verify TLS against certifi's CA bundle — same rationale as scripts/daily_webhook.py.
try:
    import certifi

    _SSL_CONTEXT: ssl.SSLContext | None = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = None


def _post_credentials(base_url: str, agent: str, transport: str):
    settings.require("engine_api_key")
    url = base_url.rstrip("/") + f"/credentials/{agent}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"transport": transport}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {settings.engine_api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"Could not reach {url}: {e.reason}", file=sys.stderr)
        print("Is the dispatcher running? (uv run uvicorn app.main:app)", file=sys.stderr)
        sys.exit(1)


_HINTS = {
    401: "Bearer rejected — does ENGINE_API_KEY in .env match the deployed engine's?",
    404: "Unknown agent — check the --agent name against app/agents.py.",
    503: "Transport not configured — set DAILY_API_KEY or the LIVEKIT_* trio on the engine.",
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Provision direct-mode credentials for the Conduit app."
    )
    parser.add_argument("--transport", required=True, choices=["daily", "livekit"])
    parser.add_argument("--agent", default="loopback", help="Agent id (default: loopback).")
    parser.add_argument(
        "--base-url",
        default=settings.public_base_url or "http://localhost:8000",
        help="Dispatcher base URL (default: PUBLIC_BASE_URL or http://localhost:8000).",
    )
    parser.add_argument("--json", action="store_true", help="Print the raw payload instead.")
    args = parser.parse_args()

    status, body = _post_credentials(args.base_url, args.agent, args.transport)
    if status != 200:
        print(f"HTTP {status}")
        print(json.dumps(body, indent=2) if isinstance(body, dict) else body)
        if hint := _HINTS.get(status):
            print(f"\n⚠️  {hint}")
        sys.exit(1)

    if args.json:
        print(json.dumps(body, indent=2))
        return

    conn = body["connection"]
    print(f"\nDirect credentials for agent '{body['agent_id']}' ({body['transport']})")
    print("Paste into Conduit → Add Agent → Direct room (advanced):\n")
    print(f"  Room URL : {conn['room_url']}")
    print(f"  Token    : {conn['token']}\n")
    if room_name := conn.get("room_name"):
        print(f"  (LiveKit room '{room_name}' — the token scopes it; the URL stays constant.)")
    if body.get("expires_at"):
        print(f"Expires: {body['expires_at']}  (gates the initial connect only, not reconnects)")
    webhook_hint = (
        "scripts/daily_webhook.py register"
        if body["transport"] == "daily"
        else "the LiveKit Cloud dashboard (docs/direct-mode.md)"
    )
    print(f"\nNOTE: direct mode dispatches via the SFU webhook — register it via {webhook_hint}.")


if __name__ == "__main__":
    main()
